// SPDX-License-Identifier: Apache-2.0
// Mjolnir fleet exporter and Varlink action service.
// No shell or interpreter is used; all work is done with libc, json-c and
// compiled tools that are already in the image.

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <json-c/json.h>
#include <systemd/sd-daemon.h>

#define KUBECONFIG "/run/mjolnir/fleet.kubeconfig"
#define STATUS_FILE "/run/mjolnir/mjolnirnode.yaml"

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

// Run a command and capture its stdout (trimmed). Returns 0 on success.
static int run_capture(const char *const argv[], char *out, size_t outsz) {
    out[0] = '\0';
    int fds[2];
    if (pipe(fds) < 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(fds[0]); close(fds[1]); return -1; }
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], 1);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, 2); close(devnull); }
        execv(argv[0], (char *const *)argv);
        _exit(127);
    }
    close(fds[1]);
    size_t total = 0;
    ssize_t n;
    while (total < outsz - 1 && (n = read(fds[0], out + total, outsz - 1 - total)) > 0)
        total += (size_t)n;
    out[total] = '\0';
    close(fds[0]);
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
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
    DIR *d = opendir("/var/lib/iwd");
    if (!d) return NULL;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t len = strlen(e->d_name);
        if (len > 4 && !strcmp(e->d_name + len - 4, ".psk")) {
            char *ssid = strndup(e->d_name, len - 4);
            closedir(d);
            return ssid;
        }
    }
    closedir(d);
    return NULL;
}

static char *wifi_interface(void) {
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

static char *wifi_signal(const char *ifname) {
    if (!ifname) return strdup("");
    char path[256], out[8192];
    snprintf(path, sizeof(path), "/net.connman.iwd/%s/Station", ifname);
    const char *argv[] = { "/usr/bin/busctl", "--json=short", "get-property",
                           "io.iwd", path, "io.iwd.Station", "Signal", NULL };
    if (run_capture(argv, out, sizeof(out)) != 0) return strdup("");
    json_object *j = json_tokener_parse(out);
    if (!j) return strdup("");
    json_object *v = NULL;
    const char *s = "";
    if (json_object_get_type(j) == json_type_object && json_object_object_get_ex(j, "value", &v))
        s = json_object_get_string(v);
    char *result = strdup(s ? s : "");
    json_object_put(j);
    return result;
}

static char *wifi_state(const char *ifname) {
    if (!ifname) return strdup("absent");
    char out[16384];
    const char *argv[] = { "/usr/bin/ip", "-j", "link", "show", "dev", ifname, NULL };
    if (run_capture(argv, out, sizeof(out)) != 0) return strdup("unknown");
    json_object *j = json_tokener_parse(out);
    if (!j) return strdup("unknown");
    const char *s = "unknown";
    if (json_object_get_type(j) == json_type_array) {
        json_object *o = json_object_array_get_idx(j, 0);
        json_object *v = NULL;
        if (o && json_object_object_get_ex(o, "operstate", &v))
            s = json_object_get_string(v);
    }
    char *result = strdup(s ? s : "unknown");
    json_object_put(j);
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

    // WiFi client state
    char *ssid = wifi_ssid();
    char *ifname = wifi_interface();
    json_object *wifi = json_object_new_object();
    json_object_object_add(wifi, "ssid", json_object_new_string(ssid ? ssid : ""));
    json_object_object_add(wifi, "interface", json_object_new_string(ifname ? ifname : ""));
    json_object_object_add(wifi, "state", json_object_new_string(wifi_state(ifname)));
    json_object_object_add(wifi, "signal", json_object_new_string(wifi_signal(ifname)));
    json_object_object_add(root, "wifi", wifi);

    free(name); free(role); free(host); free(ssid); free(ifname);
    return root;
}

static void cmd_status(void) {
    json_object *j = build_status();
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
        return o;
    }
    if (!strcmp(method, "io.mjolnir.Fleet.Status")) return build_status();
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
        return action_result("clear-reboot-lock", "reboot lock cleared");
    }
    if (!strcmp(method, "io.mjolnir.Fleet.Reboot")) {
        unlink("/run/kubestellar-reboot-deferred");
        const char *argv[] = { "/usr/bin/systemctl", "reboot", NULL };
        int rc = run_quiet(argv);
        char msg[256];
        snprintf(msg, sizeof(msg), rc == 0 ? "reboot requested" : "reboot request failed (%d)", rc);
        return action_result("reboot", msg);
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
    else if (!strcmp(argv[1], "publish")) cmd_publish();
    else if (!strcmp(argv[1], "varlink")) cmd_varlink();
    else {
        fprintf(stderr, "mjolnir-fleet: unknown command %s\n", argv[1]);
        return 2;
    }
    return 0;
}
