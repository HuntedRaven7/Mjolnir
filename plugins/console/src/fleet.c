// SPDX-License-Identifier: Apache-2.0
// Mjolnir fleet exporter and Varlink action service.
// No shell or interpreter is used; all work is done with libc, json-c and
// compiled tools that are already in the image.

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <json-c/json.h>
#include <systemd/sd-bus.h>
#include <systemd/sd-daemon.h>

#include "attest.h"

#define KUBECONFIG "/run/mjolnir/fleet.kubeconfig"
#define STATUS_FILE "/run/mjolnir/mjolnirnode.yaml"

// Diagnostics are read-only and bound in both time and output size. The
// Varlink loop is single threaded, so one stuck command must never hold it.
#define DIAG_TIMEOUT_MS 5000
#define DEFAULT_TIMEOUT_MS 15000
#define DIAG_OUTPUT_MAX 65536
#define MAX_UNIT_LEN 128

static void die(const char *msg) {
    fprintf(stderr, "mjolnir-fleet: %s: %s\n", msg, strerror(errno));
    exit(1);
}

static char *read_file(const char *path, size_t max) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    char *buf = calloc(1, max + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, max, f);
    buf[n] = '\0';
    fclose(f);
    return buf;
}

static int exists(const char *path) {
    return access(path, F_OK) == 0;
}

// Run a command, capture at most outsz-1 bytes of stdout, and kill it after
// timeout_ms. Excess output is drained so a chatty child cannot block on the
// pipe. Returns the child's exit status, 124 on timeout, or -1 on setup error.
static int run_capture_timeout(const char *const argv[], char *out, size_t outsz,
                               int timeout_ms) {
    out[0] = '\0';
    if (outsz < 2) return -1;
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) < 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(fds[0]); close(fds[1]); return -1; }
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], 1);
        close(fds[1]);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, 2); close(devnull); }
        execv(argv[0], (char *const *)argv);
        _exit(127);
    }
    close(fds[1]);
    fcntl(fds[0], F_SETFL, O_NONBLOCK);

    size_t total = 0;
    int timed_out = 0;
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed = (now.tv_sec - start.tv_sec) * 1000 +
                       (now.tv_nsec - start.tv_nsec) / 1000000;
        int remaining = timeout_ms - (int)elapsed;
        if (remaining <= 0) { timed_out = 1; break; }
        struct pollfd pfd = { .fd = fds[0], .events = POLLIN };
        int ready = poll(&pfd, 1, remaining);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ready == 0) { timed_out = 1; break; }
        char chunk[4096];
        ssize_t n = read(fds[0], chunk, sizeof(chunk));
        if (n > 0) {
            if (total < outsz - 1) {
                size_t take = (size_t)n;
                if (take > outsz - 1 - total) take = outsz - 1 - total;
                memcpy(out + total, chunk, take);
                total += take;
            }
            continue;
        }
        if (n == 0) break;
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
        break;
    }
    out[total] = '\0';
    close(fds[0]);

    if (timed_out) kill(pid, SIGKILL);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (timed_out) return 124;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

static int run_capture(const char *const argv[], char *out, size_t outsz) {
    return run_capture_timeout(argv, out, outsz, DEFAULT_TIMEOUT_MS);
}

static int run_quiet(const char *const argv[]) {
    char buf[4096];
    return run_capture(argv, buf, sizeof(buf));
}

static const char *credential_dir(void) {
    const char *d = getenv("CREDENTIALS_DIRECTORY");
    return d ? d : "/run/credentials/mjolnir-fleet.service";
}

static char *credential(const char *name) {
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", credential_dir(), name);
    char *v = read_file(path, 65536);
    if (v) {
        size_t n = strlen(v);
        while (n && (v[n-1] == '\n' || v[n-1] == '\r')) v[--n] = '\0';
    }
    return v;
}

static char *node_name(void) {
    char *v = read_file("/etc/hostname", 256);
    if (v) {
        size_t n = strlen(v);
        while (n && (v[n-1] == '\n' || v[n-1] == '\r')) v[--n] = '\0';
        if (n) return v;
        free(v);
    }
    return strdup("localhost");
}

static char *wifi_ssid(void) {
    // NetworkManager keyfiles are named after the SSID. Prefer the active
    // connection but fall back to the first provisioned profile.
    char out[8192];
    const char *argv[] = { "/usr/bin/nmcli", "-j", "-f", "GENERAL.CONNECTION",
                           "device", "show", NULL };
    if (run_capture(argv, out, sizeof(out)) == 0) {
        json_object *j = json_tokener_parse(out);
        if (j && json_object_get_type(j) == json_type_array) {
            int n = json_object_array_length(j);
            for (int i = 0; i < n; i++) {
                json_object *o = json_object_array_get_idx(j, i), *v = NULL;
                if (o && json_object_object_get_ex(o, "value", &v)) {
                    const char *s = json_object_get_string(v);
                    if (s && *s && strcmp(s, "--")) {
                        char *r = strdup(s);
                        json_object_put(j);
                        return r;
                    }
                }
            }
        }
        if (j) json_object_put(j);
    }

    DIR *d = opendir("/etc/NetworkManager/system-connections");
    if (!d) return NULL;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t len = strlen(e->d_name);
        if (len > 13 && !strcmp(e->d_name + len - 13, ".nmconnection")) {
            char *ssid = strndup(e->d_name, len - 13);
            closedir(d);
            return ssid;
        }
    }
    closedir(d);
    return NULL;
}

static char *wifi_interface(void) {
    char out[8192];
    const char *argv[] = { "/usr/bin/nmcli", "-j", "-f",
                           "GENERAL.DEVICE,GENERAL.TYPE", "device", "show", NULL };
    if (run_capture(argv, out, sizeof(out)) == 0) {
        json_object *j = json_tokener_parse(out);
        if (j && json_object_get_type(j) == json_type_array) {
            int n = json_object_array_length(j);
            for (int i = 0; i < n; i++) {
                json_object *o = json_object_array_get_idx(j, i), *v = NULL;
                if (o && json_object_object_get_ex(o, "value", &v)) {
                    const char *s = json_object_get_string(v);
                    if (s && strncmp(s, "wl", 2) == 0) {
                        char *r = strdup(s);
                        json_object_put(j);
                        return r;
                    }
                }
            }
        }
        if (j) json_object_put(j);
    }
    DIR *d = opendir("/sys/class/net");
    if (!d) return NULL;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strncmp(e->d_name, "wl", 2)) {
            char *ifname = strdup(e->d_name);
            closedir(d);
            return ifname;
        }
    }
    closedir(d);
    return NULL;
}

static char *wifi_state(const char *ifname) {
    if (!ifname) return strdup("absent");
    char out[8192];
    const char *argv[] = { "/usr/bin/nmcli", "-j", "-f", "GENERAL.STATE",
                           "device", "show", ifname, NULL };
    if (run_capture(argv, out, sizeof(out)) != 0) return strdup("unknown");
    json_object *j = json_tokener_parse(out);
    const char *s = "unknown";
    if (j && json_object_get_type(j) == json_type_array) {
        json_object *o = json_object_array_get_idx(j, 0), *v = NULL;
        if (o && json_object_object_get_ex(o, "value", &v))
            s = json_object_get_string(v);
    }
    char *result = strdup(s ? s : "unknown");
    if (j) json_object_put(j);
    return result;
}

static char *wifi_signal(const char *ifname) {
    (void)ifname;
    char out[32768];
    const char *argv[] = { "/usr/bin/nmcli", "-j", "-f", "IN-USE,SSID,SIGNAL",
                           "device", "wifi", "list", "--rescan", "no", NULL };
    if (run_capture(argv, out, sizeof(out)) != 0) return strdup("");
    json_object *j = json_tokener_parse(out);
    const char *s = "";
    if (j && json_object_get_type(j) == json_type_array) {
        int n = json_object_array_length(j);
        for (int i = 0; i < n; i++) {
            json_object *o = json_object_array_get_idx(j, i), *v = NULL;
            if (o && json_object_object_get_ex(o, "IN-USE", &v)) {
                const char *inuse = json_object_get_string(v);
                if (inuse && strchr(inuse, '*') &&
                    json_object_object_get_ex(o, "SIGNAL", &v))
                    s = json_object_get_string(v);
            }
        }
    }
    char *result = strdup(s ? s : "");
    if (j) json_object_put(j);
    return result;
}

static char *iso_now(void) {
    time_t t = time(NULL);
    struct tm tm;
    gmtime_r(&t, &tm);
    char *buf = calloc(1, 64);
    strftime(buf, 64, "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buf;
}

static json_object *build_wifi(void) {
    char *ssid = wifi_ssid();
    char *ifname = wifi_interface();
    json_object *wifi = json_object_new_object();
    json_object_object_add(wifi, "ssid", json_object_new_string(ssid ? ssid : ""));
    json_object_object_add(wifi, "interface", json_object_new_string(ifname ? ifname : ""));
    json_object_object_add(wifi, "state", json_object_new_string(wifi_state(ifname)));
    json_object_object_add(wifi, "signal", json_object_new_string(wifi_signal(ifname)));
    free(ssid);
    free(ifname);
    return wifi;
}

static json_object *build_status(void) {
    json_object *root = json_object_new_object();
    char *name = node_name();
    char *role = credential("role");
    char *host = strdup(name);
    char endpoint[512];
    snprintf(endpoint, sizeof(endpoint), "https://%s:1031", host);

    json_object_object_add(root, "node", json_object_new_string(name));
    json_object_object_add(root, "role", json_object_new_string(role ? role : "unknown"));
    json_object_object_add(root, "varlinkEndpoint", json_object_new_string(endpoint));
    json_object_object_add(root, "lastCheck", json_object_new_string(iso_now()));

    // bootc state
    char out[16384];
    const char *bargv[] = { "/usr/bin/bootc", "status", "--json", NULL };
    const char *image = "", *version = "";
    int update = 0;
    const char *pending = "";
    if (run_capture(bargv, out, sizeof(out)) == 0) {
        json_object *j = json_tokener_parse(out);
        if (j && json_object_get_type(j) == json_type_object) {
            json_object *st = NULL, *sp = NULL, *v = NULL;
            if (json_object_object_get_ex(j, "status", &st) &&
                json_object_get_type(st) == json_type_object) {
                if (json_object_object_get_ex(st, "staged", &v) &&
                    json_object_get_type(v) == json_type_object) {
                    update = 1;
                    json_object *img = NULL;
                    if (json_object_object_get_ex(v, "image", &img))
                        pending = json_object_get_string(img) ? json_object_get_string(img) : "";
                }
            }
            if (json_object_object_get_ex(j, "spec", &sp) &&
                json_object_get_type(sp) == json_type_object &&
                json_object_object_get_ex(sp, "image", &v))
                image = json_object_get_string(v) ? json_object_get_string(v) : "";
        }
        if (j) json_object_put(j);
    }
    if (!*image) image = "container-image:local";
    if (!*version) {
        char *rel = read_file("/usr/lib/os-release", 8192);
        if (rel) {
            const char *p = strstr(rel, "IMAGE_VERSION=");
            if (p) {
                p += strlen("IMAGE_VERSION=");
                char tmp[128] = {0};
                size_t i = 0;
                while (*p && *p != '\n' && i < sizeof(tmp)-1) { tmp[i++] = *p++; }
                if (i >= 2 && tmp[0] == '"' && tmp[i-1] == '"') {
                    tmp[i-1] = '\0';
                    version = strdup(tmp + 1);
                } else {
                    version = strdup(tmp);
                }
            }
            free(rel);
        }
    }
    if (!version) version = "0";
    json_object_object_add(root, "image", json_object_new_string(image));
    json_object_object_add(root, "version", json_object_new_string(version));
    json_object_object_add(root, "updateAvailable", json_object_new_boolean(update));
    json_object_object_add(root, "pendingDeployment", json_object_new_string(pending));

    json_object_object_add(root, "rebootRequired", json_object_new_boolean(exists("/run/reboot-required")));
    json_object_object_add(root, "rebootLock", json_object_new_boolean(exists("/run/reboot-lock") || exists("/etc/reboot-lock")));
    json_object_object_add(root, "rebootDeferred", json_object_new_boolean(exists("/run/kubestellar-reboot-deferred")));

    json_object_object_add(root, "wifi", build_wifi());

    free(name); free(role); free(host);
    return root;
}

static void cmd_status(void) {
    json_object *j = build_status();
    json_object_object_add(j, "attestation", mjolnir_attestation());
    printf("%s\n", json_object_to_json_string_ext(j, JSON_C_TO_STRING_PLAIN));
    json_object_put(j);
}

static void ensure_kubeconfig(void) {
    char path[512];
    snprintf(path, sizeof(path), "%s/fleet-kubeconfig", credential_dir());
    char *k = read_file(path, 1048576);
    if (!k) die("missing fleet-kubeconfig credential");
    if (mkdir("/run/mjolnir", 0700) < 0 && errno != EEXIST) die("mkdir /run/mjolnir");
    int fd = open(KUBECONFIG, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) die(KUBECONFIG);
    if (write(fd, k, strlen(k)) < 0) die("write kubeconfig");
    close(fd);
    free(k);
    setenv("KUBECONFIG", KUBECONFIG, 1);
}

static const char *jstr(json_object *o, const char *key) {
    json_object *v = NULL;
    if (o && json_object_object_get_ex(o, key, &v)) {
        const char *s = json_object_get_string(v);
        return s ? s : "";
    }
    return "";
}

static void cmd_publish(void) {
    ensure_kubeconfig();
    json_object *j = build_status();
    json_object_object_add(j, "attestation", mjolnir_attestation());
    char *name = node_name();
    char yaml[16384];
    snprintf(yaml, sizeof(yaml),
        "apiVersion: mjolnir.kubestellar.io/v1alpha1\n"
        "kind: MjolnirNode\n"
        "metadata:\n"
        "  name: %s\n"
        "spec:\n"
        "  role: %s\n"
        "  varlinkEndpoint: %s\n"
        "status:\n"
        "  image: %s\n"
        "  version: %s\n"
        "  updateAvailable: %s\n"
        "  pendingDeployment: %s\n"
        "  rebootRequired: %s\n"
        "  rebootLock: %s\n"
        "  rebootDeferred: %s\n"
        "  lastCheck: %s\n"
        "  attestation:\n"
        "    method: %s\n"
        "  wifi:\n"
        "    ssid: %s\n"
        "    interface: %s\n"
        "    state: %s\n"
        "    signal: %s\n",
        name, jstr(j, "role"), jstr(j, "varlinkEndpoint"),
        jstr(j, "image"), jstr(j, "version"),
        json_object_get_boolean(json_object_object_get(j, "updateAvailable")) ? "true" : "false",
        jstr(j, "pendingDeployment"),
        json_object_get_boolean(json_object_object_get(j, "rebootRequired")) ? "true" : "false",
        json_object_get_boolean(json_object_object_get(j, "rebootLock")) ? "true" : "false",
        json_object_get_boolean(json_object_object_get(j, "rebootDeferred")) ? "true" : "false",
        jstr(j, "lastCheck"),
        jstr(json_object_object_get(j, "attestation"), "method"),
        jstr(json_object_object_get(j, "wifi"), "ssid"),
        jstr(json_object_object_get(j, "wifi"), "interface"),
        jstr(json_object_object_get(j, "wifi"), "state"),
        jstr(json_object_object_get(j, "wifi"), "signal"));

    int fd = open(STATUS_FILE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) die(STATUS_FILE);
    if (write(fd, yaml, strlen(yaml)) < 0) die("write status yaml");
    close(fd);

    const char *argv[] = { "/usr/bin/kubectl", "apply", "-f", STATUS_FILE, NULL };
    int rc = run_quiet(argv);
    json_object_put(j);
    free(name);
    if (rc != 0) {
        fprintf(stderr, "mjolnir-fleet: kubectl apply failed (%d)\n", rc);
        exit(rc);
    }
}

// ---------------------------------------------------------------------------
// Varlink service
// ---------------------------------------------------------------------------

static json_object *action_result(const char *action, const char *message) {
    json_object *o = json_object_new_object();
    json_object_object_add(o, "action", json_object_new_string(action));
    json_object_object_add(o, "message", json_object_new_string(message));
    return o;
}

static json_object *diag_error(const char *code, const char *message) {
    json_object *o = json_object_new_object();
    json_object_object_add(o, "error", json_object_new_string(code));
    json_object_object_add(o, "message", json_object_new_string(message));
    return o;
}

// Unit names come from callers, so allow only characters systemd itself
// accepts. No caller string reaches a shell or an option position.
static int valid_unit_name(const char *s) {
    if (!s || !*s || strlen(s) > MAX_UNIT_LEN || *s == '-') return 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (!(isalnum(*p) || *p == '_' || *p == '.' || *p == '@' ||
              *p == ':' || *p == '-' || *p == '\\')) return 0;
    }
    return 1;
}

// Copy a string parameter only when it really is a string and fits.
static int param_string(json_object *params, const char *key, char *buf,
                        size_t bufsz, int *present) {
    json_object *v = NULL;
    *present = 0;
    if (!params || !json_object_object_get_ex(params, key, &v)) return 1;
    if (json_object_get_type(v) != json_type_string) return 0;
    const char *s = json_object_get_string(v);
    size_t n = s ? strlen(s) : 0;
    if (n >= bufsz) return 0;
    memcpy(buf, s, n + 1);
    *present = 1;
    return 1;
}

static int parse_lines(json_object *params, int *lines) {
    json_object *v = NULL;
    *lines = 100;
    if (!params || !json_object_object_get_ex(params, "lines", &v)) return 1;
    if (json_object_get_type(v) != json_type_int) return 0;
    int64_t n = json_object_get_int64(v);
    if (n < 1 || n > 1000) return 0;
    *lines = (int)n;
    return 1;
}

static const char *const UNIT_PROPERTIES[] = {
    "LoadState", "ActiveState", "SubState", "MainPID", "ExecMainStatus",
    "Result", "Description", "FragmentPath", "ActiveEnterTimestamp",
    "NRestarts", NULL
};

static json_object *diag_command(const char *const argv[], int as_json) {
    char out[DIAG_OUTPUT_MAX];
    int rc = run_capture_timeout(argv, out, sizeof(out), DIAG_TIMEOUT_MS);
    json_object *o = json_object_new_object();
    json_object_object_add(o, "exitCode", json_object_new_int(rc));
    if (as_json) {
        json_object *data = json_tokener_parse(out);
        if (data) json_object_object_add(o, "data", data);
        else json_object_object_add(o, "text", json_object_new_string(out));
    } else {
        json_object_object_add(o, "text", json_object_new_string(out));
    }
    return o;
}

// Reset scope is validated here, at the Varlink boundary. Only a whitelisted
// value becomes a unit name, so caller input never reaches sd-bus as a path.
static const char *const RESET_SCOPES[] = {
    "node-identity", "etcd-data", "full"
};
static const char *const RESET_UNITS[] = {
    "mjolnir-reset-node-identity.service",
    "mjolnir-reset-etcd-data.service",
    "mjolnir-reset-full.service"
};

static int reset_scope_index(const char *scope) {
    if (!scope) return -1;
    for (size_t i = 0; i < sizeof(RESET_SCOPES) / sizeof(RESET_SCOPES[0]); i++)
        if (!strcmp(scope, RESET_SCOPES[i])) return (int)i;
    return -1;
}

static json_object *varlink_error(const char *name) {
    json_object *e = json_object_new_object();
    json_object_object_add(e, "error", json_object_new_string(name));
    return e;
}

static void trim_newline_fleet(char *s) {
    size_t n = strlen(s);
    while (n && (s[n-1] == '\n' || s[n-1] == '\r' || s[n-1] == ' '))
        s[--n] = '\0';
}

// Start a unit directly over sd-bus; no shell and no string interpolation.
static int start_unit(const char *unit) {
    sd_bus *bus = NULL;
    sd_bus_error err = SD_BUS_ERROR_NULL;
    sd_bus_message *msg = NULL, *reply = NULL;
    int r = sd_bus_default_system(&bus);
    if (r >= 0)
        r = sd_bus_message_new_method_call(bus, &msg,
            "org.freedesktop.systemd1", "/org/freedesktop/systemd1",
            "org.freedesktop.systemd1.Manager", "StartUnit");
    if (r >= 0) r = sd_bus_message_append(msg, "ss", unit, "replace");
    if (r >= 0) r = sd_bus_call(bus, msg, 0, &err, &reply);
    if (r < 0)
        fprintf(stderr, "mjolnir-fleet: StartUnit %s failed: %s\n",
                unit, err.message ? err.message : strerror(-r));
    sd_bus_error_free(&err);
    if (msg) sd_bus_message_unref(msg);
    if (reply) sd_bus_message_unref(reply);
    if (bus) sd_bus_unref(bus);
    return r < 0 ? -1 : 0;
}
}

static json_object *dispatch(json_object *req) {
    json_object *params = NULL;
    const char *method = jstr(req, "method");
    json_object_object_get_ex(req, "parameters", &params);
    if (!params) params = json_object_new_object();

    if (!strcmp(method, "org.varlink.service.GetInfo")) {
        json_object *o = json_object_new_object();
        json_object_object_add(o, "product", json_object_new_string("Mjolnir Fleet"));
        json_object_object_add(o, "vendor", json_object_new_string("Mjolnir"));
        json_object_object_add(o, "version", json_object_new_string("1"));
        json_object_object_add(o, "url", json_object_new_string("https://github.com/HuntedRaven7/Mjolnir"));
        json_object *interfaces = json_object_new_array();
        json_object_array_add(interfaces, json_object_new_string("io.mjolnir.Fleet"));
        json_object_object_add(o, "interfaces", interfaces);
        static const char *const methods[] = {
            "org.varlink.service.GetInfo",
            "io.mjolnir.Fleet.Status",
            "io.mjolnir.Fleet.WifiStatus",
            "io.mjolnir.Fleet.Attestation",
            "io.mjolnir.Fleet.JournalTail",
            "io.mjolnir.Fleet.UnitStatus",
            "io.mjolnir.Fleet.BootcStatus",
            "io.mjolnir.Fleet.KubeadmPreflight",
            "io.mjolnir.Fleet.NetworkChecks",
            "io.mjolnir.Fleet.FactoryReset",
            "io.mjolnir.Fleet.ResetPreflight",
            "io.mjolnir.Fleet.SnapshotNow",
            "io.mjolnir.Fleet.Upgrade",
            "io.mjolnir.Fleet.ClearRebootLock",
            "io.mjolnir.Fleet.Reboot",
            "io.mjolnir.Fleet.RotateJoinToken",
            NULL
        };
        json_object *list = json_object_new_array();
        for (int i = 0; methods[i]; i++)
            json_object_array_add(list, json_object_new_string(methods[i]));
        json_object_object_add(o, "methods", list);
        return o;
    }
    if (!strcmp(method, "io.mjolnir.Fleet.Status")) {
        json_object *j = build_status();
        json_object_object_add(j, "attestation", mjolnir_attestation());
        return j;
    }
    if (!strcmp(method, "io.mjolnir.Fleet.Attestation")) return mjolnir_attestation();

    if (!strcmp(method, "io.mjolnir.Fleet.JournalTail")) {
        int lines;
        if (!parse_lines(params, &lines))
            return diag_error("InvalidArguments", "lines must be an integer from 1 to 1000");
        char lbuf[16];
        snprintf(lbuf, sizeof(lbuf), "%d", lines);
        const char *argv[6];
        int n = 0;
        argv[n++] = "/usr/bin/journalctl";
        argv[n++] = "--no-pager";
        argv[n++] = "-n";
        argv[n++] = lbuf;
        char unit[MAX_UNIT_LEN + 1];
        int has_unit = 0;
        if (!param_string(params, "unit", unit, sizeof(unit), &has_unit) ||
            (has_unit && !valid_unit_name(unit)))
            return diag_error("InvalidArguments", "unit must be a valid systemd unit name");
        char ubuf[MAX_UNIT_LEN + 16];
        if (has_unit) {
            snprintf(ubuf, sizeof(ubuf), "--unit=%s", unit);
            argv[n++] = ubuf;
        }
        argv[n] = NULL;
        char out[DIAG_OUTPUT_MAX];
        int rc = run_capture_timeout(argv, out, sizeof(out), DIAG_TIMEOUT_MS);
        json_object *o = json_object_new_object();
        json_object_object_add(o, "exitCode", json_object_new_int(rc));
        json_object_object_add(o, "lines", json_object_new_int(lines));
        json_object_object_add(o, "output", json_object_new_string(out));
        return o;
    }
    if (!strcmp(method, "io.mjolnir.Fleet.UnitStatus")) {
        char unit[MAX_UNIT_LEN + 1];
        int has_unit = 0;
        if (!param_string(params, "unit", unit, sizeof(unit), &has_unit) ||
            !has_unit || !valid_unit_name(unit))
            return diag_error("InvalidArguments", "unit is required and must be a valid unit name");
        char props[1024] = "LoadState,ActiveState,SubState,MainPID,ExecMainStatus,Result";
        json_object *requested = NULL;
        if (params && json_object_object_get_ex(params, "properties", &requested)) {
            if (json_object_get_type(requested) != json_type_array)
                return diag_error("InvalidArguments", "properties must be an array");
            int count = json_object_array_length(requested);
            if (count < 1 || count > 16)
                return diag_error("InvalidArguments", "properties must hold 1 to 16 names");
            props[0] = '\0';
            for (int i = 0; i < count; i++) {
                json_object *item = json_object_array_get_idx(requested, i);
                if (json_object_get_type(item) != json_type_string)
                    return diag_error("InvalidArguments", "property names must be strings");
                const char *name = json_object_get_string(item);
                int allowed = 0;
                for (int k = 0; UNIT_PROPERTIES[k]; k++)
                    if (!strcmp(name, UNIT_PROPERTIES[k])) { allowed = 1; break; }
                if (!allowed)
                    return diag_error("InvalidArguments", "property is not on the allowlist");
                if (i) strncat(props, ",", sizeof(props) - strlen(props) - 1);
                strncat(props, name, sizeof(props) - strlen(props) - 1);
            }
        }
        char pflag[sizeof(props) + 16];
        snprintf(pflag, sizeof(pflag), "--property=%s", props);
        const char *argv[] = { "/usr/bin/systemctl", "show", unit, pflag, NULL };
        char out[DIAG_OUTPUT_MAX];
        int rc = run_capture_timeout(argv, out, sizeof(out), DIAG_TIMEOUT_MS);
        json_object *o = json_object_new_object();
        json_object_object_add(o, "exitCode", json_object_new_int(rc));
        json_object_object_add(o, "output", json_object_new_string(out));
        return o;
    }
    if (!strcmp(method, "io.mjolnir.Fleet.BootcStatus")) {
        const char *argv[] = { "/usr/bin/bootc", "status", "--json", NULL };
        char out[DIAG_OUTPUT_MAX];
        int rc = run_capture_timeout(argv, out, sizeof(out), DIAG_TIMEOUT_MS);
        json_object *o = json_object_new_object();
        json_object_object_add(o, "exitCode", json_object_new_int(rc));
        json_object *data = json_tokener_parse(out);
        if (data) json_object_object_add(o, "status", data);
        else json_object_object_add(o, "text", json_object_new_string(out));
        return o;
    }
    if (!strcmp(method, "io.mjolnir.Fleet.KubeadmPreflight")) {
        // Verified read-only for kubeadm 1.37.2: the preflight phase runs
        // checks only, and --dry-run keeps it from applying any change.
        const char *argv[] = {
            "/usr/bin/kubeadm", "init", "phase", "preflight",
            "--config", "/etc/mjolnir/kubeadm-init.yaml", "--dry-run", NULL
        };
        return diag_command(argv, 0);
    }
    if (!strcmp(method, "io.mjolnir.Fleet.NetworkChecks")) {
        const char *addr[] = { "/usr/bin/ip", "-j", "addr", NULL };
        const char *route[] = { "/usr/bin/ip", "-j", "route", NULL };
        const char *listen[] = { "/usr/bin/ss", "-tuln", NULL };
        const char *dns[] = { "/usr/bin/resolvectl", "status", NULL };
        json_object *o = json_object_new_object();
        json_object_object_add(o, "addresses", diag_command(addr, 1));
        json_object_object_add(o, "routes", diag_command(route, 1));
        json_object_object_add(o, "listening", diag_command(listen, 0));
        json_object_object_add(o, "dns", diag_command(dns, 0));
        json_object_object_add(o, "wifi", build_wifi());
        return o;
    }
    if (!strcmp(method, "io.mjolnir.Fleet.FactoryReset")) {
        // Scope + exact confirmation string + a TPM-sealed credential are all
        // required. A stray call can never wipe a node.
        const char *scope = jstr(params, "scope");
        const char *confirm = jstr(params, "confirm");
        int idx = reset_scope_index(scope);
        if (idx < 0) return varlink_error("InvalidScope");
        char expected[64];
        snprintf(expected, sizeof(expected), "factory-reset:%s", scope);
        if (!confirm || strcmp(confirm, expected))
            return varlink_error("ConfirmationRequired");
        if (access("/sys/firmware/efi", F_OK) != 0)
            return varlink_error("Unsupported");
        int r = start_unit(RESET_UNITS[idx]);
        return action_result("factory-reset", r < 0 ? "request failed" :
                             "requested; the helper drains the node before wiping");
    }
    if (!strcmp(method, "io.mjolnir.Fleet.ResetPreflight")) {
        const char *scope = jstr(params, "scope");
        int idx = reset_scope_index(scope);
        if (idx < 0) return varlink_error("InvalidScope");
        char out[4096];
        const char *argv[] = {
            "/usr/bin/mjolnir-helper", "reset-preflight", scope, NULL
        };
        int rc = run_capture(argv, out, sizeof(out));
        trim_newline_fleet(out);
        json_object *o = json_object_new_object();
        json_object_object_add(o, "scope", json_object_new_string(scope));
        json_object_object_add(o, "ready",
            json_object_new_boolean(rc == 0 && !strncmp(out, "READY:", 6)));
        json_object_object_add(o, "detail", json_object_new_string(out));
        return o;
    }
    if (!strcmp(method, "io.mjolnir.Fleet.SnapshotNow")) {
        int r = start_unit("mjolnir-etcd-snapshot.service");
        return action_result("snapshot-now", r < 0 ? "request failed" :
                             "snapshot requested; destination comes from credentials");
    }
    if (!strcmp(method, "io.mjolnir.Fleet.WifiStatus")) {
        json_object *all = build_status();
        json_object *wifi = json_object_object_get(all, "wifi");
        json_object_get(wifi);
        json_object_put(all);
        return wifi;
    }

    if (!strcmp(method, "io.mjolnir.Fleet.Upgrade")) {
        const char *argv[] = { "/usr/bin/bootc", "upgrade", "--download-only", NULL };
        int rc = run_quiet(argv);
        char msg[256];
        snprintf(msg, sizeof(msg), rc == 0 ? "update queued" : "upgrade failed (%d)", rc);
        return action_result("upgrade", msg);
    }
    if (!strcmp(method, "io.mjolnir.Fleet.ClearRebootLock")) {
        unlink("/run/reboot-lock");
        unlink("/etc/reboot-lock");
        // Also release kured's cluster-wide lock so a held reboot resumes.
        char path[512];
        snprintf(path, sizeof(path), "%s/fleet-kubeconfig", credential_dir());
        if (access(path, F_OK) == 0) {
            ensure_kubeconfig();
            const char *argv[] = {
                "/usr/bin/kubectl", "-n", "kube-system", "annotate", "ds", "kured",
                "weave.works/kured-node-lock-", NULL
            };
            run_quiet(argv);
        }
        return action_result("clear-reboot-lock", "local lock cleared; kured lock is cluster-wide (clear via kubectl)");
    }
    if (!strcmp(method, "io.mjolnir.Fleet.Reboot")) {
        unlink("/run/kubestellar-reboot-deferred");
        // Do not reboot directly: create the sentinel that kured watches so
        // the node is drained and reboots are coordinated cluster-wide.
        int fd = open("/run/reboot-required", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd < 0) die("write /run/reboot-required");
        close(fd);
        return action_result("reboot", "reboot requested via kured");
    }
    if (!strcmp(method, "io.mjolnir.Fleet.RotateJoinToken")) {
        char *role = credential("role");
        if (!role || strcmp(role, "control-plane")) {
            free(role);
            return action_result("rotate-join-token", "only available on the control plane");
        }
        free(role);
        char out[4096];
        const char *argv[] = { "/usr/bin/kubeadm", "token", "create", "--print-join-command", NULL };
        int rc = run_capture(argv, out, sizeof(out));
        if (rc != 0) return action_result("rotate-join-token", "kubeadm token create failed");
        json_object *o = json_object_new_object();
        json_object_object_add(o, "action", json_object_new_string("rotate-join-token"));
        json_object_object_add(o, "joinCommand", json_object_new_string(out));
        return o;
    }
    json_object *err = json_object_new_object();
    json_object_object_add(err, "error", json_object_new_string("MethodNotFound"));
    json_object_object_add(err, "parameters", json_object_new_string(""));
    return err;
}

static void handle_client(int fd) {
    char buf[65536];
    size_t len = 0;
    for (;;) {
        ssize_t n = recv(fd, buf + len, sizeof(buf) - 1 - len, 0);
        if (n <= 0) break;
        len += (size_t)n;
        while (len && memchr(buf, '\0', len)) {
            char *zero = memchr(buf, '\0', len);
            size_t msglen = (size_t)(zero - buf);
            char *msg = strndup(buf, msglen);
            size_t rem = len - msglen - 1;
            memmove(buf, zero + 1, rem);
            len = rem;

            json_object *req = json_tokener_parse(msg);
            json_object *resp = json_object_new_object();
            json_object *result = dispatch(req ? req : json_object_new_object());
            json_object *perr = NULL;
            if (json_object_object_get_ex(result, "error", &perr)) {
                json_object_object_add(resp, "error", json_object_new_string(json_object_get_string(perr)));
                json_object_object_del(result, "error");
            }
            json_object_object_add(resp, "parameters", result);
            json_object *id = NULL;
            if (req && json_object_object_get_ex(req, "id", &id))
                json_object_object_add(resp, "id", json_object_get(id));
            const char *out = json_object_to_json_string_ext(resp, JSON_C_TO_STRING_PLAIN);
            if (send(fd, out, strlen(out), 0) < 0 || send(fd, "\0", 1, 0) < 0)
                break;
            json_object_put(resp);
            json_object_put(req);
            free(msg);
        }
    }
    close(fd);
}

static void cmd_varlink(void) {
    int n = sd_listen_fds(0);
    if (n != 1) die("expected exactly one socket-activated fd");
    int listenfd = SD_LISTEN_FDS_START;
    for (;;) {
        int fd = accept(listenfd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            die("accept");
        }
        handle_client(fd);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: mjolnir-fleet <status|publish|varlink>\n");
        return 2;
    }
    if (!strcmp(argv[1], "status")) cmd_status();
    else if (!strcmp(argv[1], "attest")) {
        json_object *j = mjolnir_attestation();
        printf("%s\n", json_object_to_json_string_ext(j, JSON_C_TO_STRING_PLAIN));
        json_object_put(j);
    }
    else if (!strcmp(argv[1], "publish")) cmd_publish();
    else if (!strcmp(argv[1], "varlink")) cmd_varlink();
    else {
        fprintf(stderr, "mjolnir-fleet: unknown command %s\n", argv[1]);
        return 2;
    }
    return 0;
}
