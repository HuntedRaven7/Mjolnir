// SPDX-License-Identifier: Apache-2.0
// Mjolnir host helper. Compiled C: there is no shell or interpreter in the
// image, so all orchestration that would normally be a script lives here.
//
// Usage: mjolnir-helper <init|join|wifi|apply|wait-api|reboot|snapshot-etcd>
//        mjolnir-helper <reset|reset-preflight> <node-identity|etcd-data|full>

#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#define ADMIN_CONF "/etc/kubernetes/admin.conf"
#define KUBELET_CONF "/etc/kubernetes/kubelet.conf"
#define KUBECONFIG "/root/.kube/config"
#define MANIFEST_DIR "/usr/share/mjolnir/manifests"

static void die(const char *msg) {
    fprintf(stderr, "mjolnir-helper: %s: %s\n", msg, strerror(errno));
    exit(1);
}

static void trim_newline(char *s) {
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' '))
        s[--n] = '\0';
}

// Read a systemd credential by name. systemd mounts the credential directory
// at $CREDENTIALS_DIRECTORY for the unit; fall back to /run/credentials/<unit>.
static int read_credential(const char *name, char *buf, size_t size) {
    const char *dir = getenv("CREDENTIALS_DIRECTORY");
    char path[512];
    if (dir)
        snprintf(path, sizeof(path), "%s/%s", dir, name);
    else
        snprintf(path, sizeof(path), "/run/credentials/mjolnir/%s", name);

    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        // System credentials set with systemd.set_credential= live here.
        snprintf(path, sizeof(path), "/run/credentials/@system/%s", name);
        fd = open(path, O_RDONLY | O_CLOEXEC);
    }
    if (fd < 0)
        return -1;
    ssize_t n = read(fd, buf, size - 1);
    close(fd);
    if (n < 0)
        return -1;
    buf[n] = '\0';
    trim_newline(buf);
    return 0;
}

static void write_file(const char *path, const char *data, mode_t mode) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    if (fd < 0)
        die(path);
    if (write(fd, data, strlen(data)) < 0)
        die(path);
    close(fd);
    if (chmod(path, mode) < 0)
        die(path);
}

static void run(const char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0)
        die("fork");
    if (pid == 0) {
        execv(argv[0], (char *const *)argv);
        fprintf(stderr, "mjolnir-helper: exec %s: %s\n", argv[0], strerror(errno));
        _exit(127);
    }
    int status;
    while (waitpid(pid, &status, 0) < 0)
        if (errno != EINTR)
            die("waitpid");
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        exit(WIFEXITED(status) ? WEXITSTATUS(status) : 1);
}

static void nap(unsigned seconds) {
    struct timespec ts = { .tv_sec = seconds, .tv_nsec = 0 };
    nanosleep(&ts, NULL);
}

// ---------------------------------------------------------------------------
// control-plane bootstrap
// ---------------------------------------------------------------------------
static int cmd_init(void) {
    char role[128] = {0};
    if (read_credential("role", role, sizeof(role)) < 0 || strcmp(role, "control-plane") != 0) {
        fprintf(stderr, "mjolnir-helper: role is not control-plane; nothing to do\n");
        return 0;
    }
    if (access(ADMIN_CONF, F_OK) == 0) {
        fprintf(stderr, "mjolnir-helper: cluster already initialized\n");
        return 0;
    }
    setenv("HOME", "/root", 1);
    const char *argv[] = {
        "/usr/bin/kubeadm", "init",
        "--config", "/etc/mjolnir/kubeadm-init.yaml",
        "--skip-phases=addon/kube-proxy",
        NULL
    };
    run(argv);
    return 0;
}

// ---------------------------------------------------------------------------
// worker join
// ---------------------------------------------------------------------------
static int cmd_join(void) {
    char role[128] = {0}, token[256] = {0}, hash[256] = {0}, endpoint[256] = {0};
    if (read_credential("role", role, sizeof(role)) < 0 || strcmp(role, "worker") != 0) {
        fprintf(stderr, "mjolnir-helper: role is not worker; nothing to do\n");
        return 0;
    }
    if (access(KUBELET_CONF, F_OK) == 0) {
        fprintf(stderr, "mjolnir-helper: node already joined\n");
        return 0;
    }
    if (read_credential("join-token", token, sizeof(token)) < 0 ||
        read_credential("ca-cert-hash", hash, sizeof(hash)) < 0 ||
        read_credential("control-plane-endpoint", endpoint, sizeof(endpoint)) < 0)
        die("missing join credentials");
    setenv("HOME", "/root", 1);
    const char *argv[] = {
        "/usr/bin/kubeadm", "join", endpoint,
        "--token", token,
        "--discovery-token-ca-cert-hash", hash,
        NULL
    };
    run(argv);
    return 0;
}

// ---------------------------------------------------------------------------
// WiFi client provisioning (NetworkManager + wpa-supplicant)
// ---------------------------------------------------------------------------
// Deterministic UUID for a connection profile, derived from the SSID, so
// reprovisioning the same network updates the same connection.
static void connection_uuid(const char *ssid, char out[37]) {
    uint64_t h1 = 1469598103934665603ULL, h2 = 1469598103934665603ULL;
    for (const unsigned char *p = (const unsigned char *)ssid; *p; p++) {
        h1 = (h1 ^ *p) * 1099511628211ULL;
        h2 = (h2 ^ (uint64_t)(*p + 0x9e)) * 1099511628211ULL;
    }
    snprintf(out, 37,
             "%08x-%04x-4%03x-8%03x-%08x%04x",
             (unsigned)(h1 >> 32), (unsigned)((h1 >> 16) & 0xffff),
             (unsigned)(h1 & 0xfff), (unsigned)(h2 & 0xfff),
             (unsigned)(h2 >> 32), (unsigned)((h2 >> 16) & 0xffff));
}

static int cmd_wifi(void) {
    char ssid[256] = {0}, psk[256] = {0};
    if (read_credential("wifi-ssid", ssid, sizeof(ssid)) < 0 ||
        read_credential("wifi-psk", psk, sizeof(psk)) < 0) {
        fprintf(stderr, "mjolnir-helper: no WiFi credentials; skipping\n");
        return 0;
    }
    if (strlen(psk) != 64)
        die("wifi-psk must be a 64 character hex string");

    const char *dir = "/etc/NetworkManager/system-connections";
    if (mkdir(dir, 0700) < 0 && errno != EEXIST)
        die("mkdir system-connections");

    char uuid[37];
    connection_uuid(ssid, uuid);
    char path[512], content[1024];
    snprintf(path, sizeof(path), "%s/%s.nmconnection", dir, ssid);
    snprintf(content, sizeof(content),
             "[connection]\n"
             "id=%s\n"
             "uuid=%s\n"
             "type=wifi\n"
             "autoconnect=true\n"
             "autoconnect-priority=10\n"
             "\n"
             "[wifi]\n"
             "mode=infrastructure\n"
             "ssid=%s\n"
             "\n"
             "[wifi-security]\n"
             "key-mgmt=wpa-psk\n"
             "psk=%s\n"
             "\n"
             "[ipv4]\n"
             "method=auto\n"
             "\n"
             "[ipv6]\n"
             "method=auto\n",
             ssid, uuid, ssid, psk);
    write_file(path, content, 0600);

    const char *argv[] = { "/usr/bin/nmcli", "connection", "reload", NULL };
    run(argv);
    return 0;
}

// ---------------------------------------------------------------------------
// wait for the Kubernetes API to answer /healthz
// ---------------------------------------------------------------------------
static int cmd_wait_api(void) {
    const char *kubeconfig = access(ADMIN_CONF, F_OK) == 0 ? ADMIN_CONF : KUBECONFIG;
    const char *argv[] = {
        "/usr/bin/kubectl", "--kubeconfig", kubeconfig,
        "get", "--raw", "/healthz", NULL
    };
    for (unsigned i = 0; i < 180; i++) {
        pid_t pid = fork();
        if (pid < 0)
            die("fork");
        if (pid == 0) {
            int devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) {
                dup2(devnull, 1);
                dup2(devnull, 2);
            }
            execv(argv[0], (char *const *)argv);
            _exit(127);
        }
        int status;
        waitpid(pid, &status, 0);
        if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
            return 0;
        nap(2);
    }
    die("Kubernetes API did not become ready");
    return 1;
}

// ---------------------------------------------------------------------------
// apply the pinned CNI / KubeStellar manifest set
// ---------------------------------------------------------------------------
static int cmd_apply(void) {
    if (cmd_wait_api() != 0)
        return 1;
    const char *kubeconfig = ADMIN_CONF;
    const char *dirs[] = {
        MANIFEST_DIR "/crds",
        MANIFEST_DIR "/kured",
        MANIFEST_DIR "/cilium",
        MANIFEST_DIR "/kubestellar"
    };
    for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
        const char *argv[] = {
            "/usr/bin/kubectl", "--kubeconfig", kubeconfig,
            "apply", "--server-side", "--force-conflicts",
            "-f", dirs[i], NULL
        };
        run(argv);
    }
    const char *rollout[] = {
        "/usr/bin/kubectl", "--kubeconfig", kubeconfig,
        "-n", "kube-system", "rollout", "status",
        "daemonset/cilium", "--timeout=10m", NULL
    };
    run(rollout);
    return 0;
}

// ---------------------------------------------------------------------------
// request a reboot by writing the sentinel kured watches. kured performs the
// cordon/drain/reboot so workloads are handled by Kubernetes.
// ---------------------------------------------------------------------------
static int cmd_reboot(void) {
    if (access("/run/reboot-lock", F_OK) == 0 || access("/etc/reboot-lock", F_OK) == 0) {
        fprintf(stderr, "mjolnir-helper: reboot held by local lock\n");
        return 0;
    }
    int fd = open("/run/reboot-required", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0)
        die("write /run/reboot-required");
    close(fd);
    return 0;
}

// ---------------------------------------------------------------------------
// scoped factory reset
//
// Every gate is fail-closed: a missing credential, an unreadable topology, an
// absent snapshot or a failed drain aborts before any file is removed. All
// external commands are compiled binaries exec'd with fixed argv arrays; no
// shell is involved anywhere.
// ---------------------------------------------------------------------------
enum reset_scope { RESET_NODE = 1, RESET_ETCD = 2, RESET_FULL = 4 };

static int parse_scope(const char *s) {
    if (!s) return 0;
    if (!strcmp(s, "node-identity")) return RESET_NODE;
    if (!strcmp(s, "etcd-data"))     return RESET_ETCD;
    if (!strcmp(s, "full"))          return RESET_FULL;
    return 0;
}

static const char *scope_name(int scope) {
    switch (scope) {
    case RESET_NODE: return "node-identity";
    case RESET_ETCD: return "etcd-data";
    case RESET_FULL: return "full";
    default:         return "invalid";
    }
}

static const char *scope_confirm(int scope) {
    switch (scope) {
    case RESET_NODE: return "factory-reset:node-identity";
    case RESET_ETCD: return "factory-reset:etcd-data";
    case RESET_FULL: return "factory-reset:full";
    default:         return "";
    }
}

// Capture stdout of a compiled tool with a hard bound. Used for topology and
// etcd member discovery; stderr stays on the journal.
static int run_capture(const char *const argv[], char *out, size_t size) {
    out[0] = '\0';
    int fds[2];
    if (pipe(fds) < 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(fds[0]); close(fds[1]); return -1; }
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], 1);
        close(fds[1]);
        execv(argv[0], (char *const *)argv);
        _exit(127);
    }
    close(fds[1]);
    size_t total = 0;
    ssize_t n;
    while (total + 1 < size && (n = read(fds[0], out + total, size - 1 - total)) > 0)
        total += (size_t)n;
    out[total] = '\0';
    close(fds[0]);
    int status;
    while (waitpid(pid, &status, 0) < 0)
        if (errno != EINTR) return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

static int expect_credential(const char *name, const char *expected) {
    char value[512] = {0};
    if (read_credential(name, value, sizeof(value)) < 0)
        return -1;
    return strcmp(value, expected) == 0 ? 0 : -1;
}

static const char *reset_kubeconfig(void) {
    if (access(ADMIN_CONF, F_OK) == 0) return ADMIN_CONF;
    return "/run/mjolnir/fleet.kubeconfig";
}

static void self_name(char *buf, size_t size) {
    if (gethostname(buf, size) != 0) die("gethostname");
    buf[size - 1] = '\0';
}

// Count control-plane nodes from the API. Zero or an unreadable API is an
// error, never "lone control plane": that would allow a destructive wipe on a
// node that has lost cluster visibility.
static int control_plane_count(void) {
    char out[16384];
    const char *argv[] = {
        "/usr/bin/kubectl", "--kubeconfig", reset_kubeconfig(),
        "get", "nodes", "-l", "node-role.kubernetes.io/control-plane",
        "-o", "name", NULL
    };
    if (run_capture(argv, out, sizeof(out)) != 0) return -1;
    int count = 0;
    for (char *line = strtok(out, "\n"); line; line = strtok(NULL, "\n"))
        if (!strncmp(line, "node/", 5) && line[5]) count++;
    return count ? count : -1;
}

static int etcd_pod(char *buf, size_t size) {
    char out[4096];
    const char *argv[] = {
        "/usr/bin/kubectl", "--kubeconfig", reset_kubeconfig(),
        "-n", "kube-system", "get", "pod", "-l", "component=etcd",
        "-o", "name", NULL
    };
    if (run_capture(argv, out, sizeof(out)) != 0) return -1;
    if (strncmp(out, "pod/etcd-", 9)) return -1;
    char *end = strpbrk(out, "\r\n");
    if (end) *end = '\0';
    snprintf(buf, size, "%s", out + 4);
    return 0;
}

// Extract the member id of this node from `etcdctl member list -o simple`.
// The first column is hex; the name column contains the Kubernetes node name.
static int member_id(const char *list, const char *self, char *out, size_t size) {
    char copy[16384];
    snprintf(copy, sizeof(copy), "%s", list);
    for (char *line = strtok(copy, "\n"); line; line = strtok(NULL, "\n")) {
        if (!strstr(line, self)) continue;
        char *end = strchr(line, ':');
        if (!end || end == line || (size_t)(end - line) >= size) return -1;
        for (char *p = line; p < end; p++)
            if (!isxdigit((unsigned char)*p)) return -1;
        *end = '\0';
        snprintf(out, size, "%s", line);
        return 0;
    }
    return -1;
}

// Multi-control-plane: remove this node from the etcd quorum before wiping
// its local data, so the remaining members keep a healthy majority.
static int remove_etcd_member(const char *self) {
    char pod[256] = {0};
    char list[16384] = {0};
    char id[64] = {0};
    if (etcd_pod(pod, sizeof(pod)) < 0) return -1;
    const char *ls[] = {
        "/usr/bin/kubectl", "--kubeconfig", reset_kubeconfig(),
        "-n", "kube-system", "exec", pod, "--",
        "/usr/local/bin/etcdctl",
        "--endpoints=https://127.0.0.1:2379",
        "--cacert=/etc/kubernetes/pki/etcd/ca.crt",
        "--cert=/etc/kubernetes/pki/etcd/server.crt",
        "--key=/etc/kubernetes/pki/etcd/server.key",
        "member", "list", "-o", "simple", NULL
    };
    if (run_capture(ls, list, sizeof(list)) != 0) return -1;
    if (member_id(list, self, id, sizeof(id)) < 0) return -1;
    const char *rm[] = {
        "/usr/bin/kubectl", "--kubeconfig", reset_kubeconfig(),
        "-n", "kube-system", "exec", pod, "--",
        "/usr/local/bin/etcdctl",
        "--endpoints=https://127.0.0.1:2379",
        "--cacert=/etc/kubernetes/pki/etcd/ca.crt",
        "--cert=/etc/kubernetes/pki/etcd/server.crt",
        "--key=/etc/kubernetes/pki/etcd/server.key",
        "member", "remove", id, NULL
    };
    return run_capture(rm, list, sizeof(list)) == 0 ? 0 : -1;
}

// Lone control plane: only a recent snapshot uploaded off-node may precede a
// wipe. The URL is a credential, never repo configuration.
static int snapshot_fresh(void) {
    struct stat st;
    char url[512] = {0};
    if (stat("/var/lib/etcd/mjolnir-snapshot.db", &st) != 0 || st.st_size < 1024)
        return -1;
    if (stat("/var/lib/mjolnir/etcd-snapshot.ok", &st) != 0) return -1;
    if (time(NULL) - st.st_mtime > 24 * 3600) return -1;
    if (read_credential("etcd-snapshot-url", url, sizeof(url)) < 0) return -1;
    return strncmp(url, "https://", 8) == 0 ? 0 : -1;
}

// kured owns reboots; drain here so a reset never races a workload or a
// staged bootc update. A failed drain exits before the wipe table runs.
static void cordon_drain(const char *node) {
    const char *cordon[] = {
        "/usr/bin/kubectl", "--kubeconfig", reset_kubeconfig(),
        "cordon", node, NULL
    };
    const char *drain[] = {
        "/usr/bin/kubectl", "--kubeconfig", reset_kubeconfig(),
        "drain", node, "--ignore-daemonsets", "--delete-emptydir-data",
        "--force", "--timeout=10m", NULL
    };
    run(cordon);
    run(drain);
}

static int unlink_cb(const char *path, const struct stat *sb, int typeflag,
                     struct FTW *ftwbuf) {
    (void)sb; (void)ftwbuf;
    if (typeflag == FTW_DP) return rmdir(path);
    return unlink(path);
}

static void remove_tree(const char *path) {
    struct stat st;
    if (lstat(path, &st) < 0) {
        if (errno == ENOENT) return;
        die(path);
    }
    if (nftw(path, unlink_cb, 20, FTW_DEPTH | FTW_PHYS) < 0)
        die(path);
}

struct reset_target { int scopes; const char *path; };

// Explicit paths only. Mountpoints are not removed: the state partition is
// reused (or recreated by systemd-repart for a full reset).
static const struct reset_target RESET_TARGETS[] = {
    { RESET_NODE | RESET_FULL, "/etc/kubernetes/kubelet.conf" },
    { RESET_NODE | RESET_FULL, "/etc/kubernetes/bootstrap-kubelet.conf" },
    { RESET_NODE | RESET_FULL, "/var/lib/kubelet/pki" },
    // Bind-mount targets are not unlinked: removing a live mountpoint returns
    // EBUSY. Remove the backed source under /var/lib/mjolnir instead.
    { RESET_NODE | RESET_FULL, "/var/lib/mjolnir/etc/machine-id" },
    { RESET_NODE | RESET_FULL, "/var/lib/mjolnir/etc/NetworkManager/system-connections" },
    { RESET_ETCD | RESET_FULL, "/var/lib/mjolnir/var/lib/etcd" },
    { RESET_ETCD | RESET_FULL, "/etc/kubernetes/pki" },
    { RESET_ETCD | RESET_FULL, "/var/lib/mjolnir/etc/kubernetes/pki" },
    { RESET_ETCD | RESET_FULL, "/etc/kubernetes/admin.conf" },
    { RESET_ETCD | RESET_FULL, "/etc/kubernetes/controller-manager.conf" },
    { RESET_ETCD | RESET_FULL, "/etc/kubernetes/scheduler.conf" }
};

static void wipe(int scope) {
    for (size_t i = 0; i < sizeof(RESET_TARGETS) / sizeof(RESET_TARGETS[0]); i++)
        if (RESET_TARGETS[i].scopes & scope)
            remove_tree(RESET_TARGETS[i].path);
}

static int cmd_reset(int scope) {
    if (!scope) die("invalid reset scope");
    char role[128] = {0}, self[128] = {0};
    int cp_count = 0;

    // Sealed confirmation: systemd decrypts this credential with TPM2 and the
    // signed PCR policy before PID 1 starts the service.
    if (expect_credential("reset-confirm", scope_confirm(scope)) < 0)
        die("missing or invalid sealed reset confirmation");
    if (read_credential("role", role, sizeof(role)) < 0) die("missing role credential");
    self_name(self, sizeof(self));

    if (strcmp(role, "control-plane") && scope != RESET_NODE)
        die("etcd-data and full reset require the control-plane role");
    if (!strcmp(role, "control-plane") && scope != RESET_NODE) {
        cp_count = control_plane_count();
        if (cp_count < 1) die("cannot determine control-plane topology");
    }
    if (cp_count == 1) {
        if (expect_credential("reset-lone-cp", "lone-cp-etcd-wipe-v1") < 0)
            die("missing second sealed confirmation for lone control plane");
        if (snapshot_fresh() < 0) die("no fresh off-node etcd snapshot");
    } else if (cp_count > 1) {
        if (remove_etcd_member(self) < 0) die("cannot remove etcd member before wipe");
    }

    cordon_drain(self);
    wipe(scope);

    if (scope == RESET_FULL) {
        // systemd-repart deletes and recreates MjolnirState on the reset boot;
        // enrollment runs again because its stamp lived on that partition.
        const char *argv[] = { "/usr/bin/systemctl", "start",
                               "mjolnir-factory-reset.target", NULL };
        run(argv);
    }
    return 0;
}

// Read-only checks for Varlink. Credential presence is checked at the standard
// encrypted store path because the caller does not have the unit credentials.
static int cmd_reset_preflight(int scope) {
    if (!scope) {
        printf("BLOCKED: invalid scope\n");
        return 1;
    }
    char role[128] = {0};
    if (read_credential("role", role, sizeof(role)) < 0 ||
        (strcmp(role, "control-plane") && scope != RESET_NODE)) {
        printf("BLOCKED: role does not permit this scope\n");
        return 1;
    }
    if (access("/etc/credstore.encrypted/reset-confirm.cred", F_OK) != 0) {
        printf("BLOCKED: sealed confirmation credential is absent\n");
        return 1;
    }
    if (!strcmp(role, "control-plane") && scope != RESET_NODE) {
        int n = control_plane_count();
        if (n < 1) {
            printf("BLOCKED: control-plane topology is unknown\n");
            return 1;
        }
        if (n == 1) {
            if (access("/etc/credstore.encrypted/reset-lone-cp.cred", F_OK) != 0) {
                printf("BLOCKED: second sealed confirmation is absent\n");
                return 1;
            }
            if (snapshot_fresh() < 0) {
                printf("BLOCKED: no fresh off-node etcd snapshot\n");
                return 1;
            }
        }
    }
    printf("READY: %s\n", scope_name(scope));
    return 0;
}

static int cmd_snapshot(void) {
    char url[512] = {0}, token[512] = {0}, auth[640] = {0}, pod[256] = {0};
    if (read_credential("etcd-snapshot-url", url, sizeof(url)) < 0 ||
        strncmp(url, "https://", 8))
        die("etcd-snapshot-url credential is missing or not https");
    read_credential("etcd-snapshot-token", token, sizeof(token));
    if (etcd_pod(pod, sizeof(pod)) < 0) die("cannot find etcd pod");

    const char *save[] = {
        "/usr/bin/kubectl", "--kubeconfig", reset_kubeconfig(),
        "-n", "kube-system", "exec", pod, "--",
        "/usr/local/bin/etcdctl",
        "--endpoints=https://127.0.0.1:2379",
        "--cacert=/etc/kubernetes/pki/etcd/ca.crt",
        "--cert=/etc/kubernetes/pki/etcd/server.crt",
        "--key=/etc/kubernetes/pki/etcd/server.key",
        "snapshot", "save", "/var/lib/etcd/mjolnir-snapshot.db", NULL
    };
    run(save);

    const char *argv[10];
    size_t n = 0;
    argv[n++] = "/usr/bin/curl";
    if (token[0]) {
        snprintf(auth, sizeof(auth), "Authorization: Bearer %s", token);
        argv[n++] = "--header";
        argv[n++] = auth;
    }
    argv[n++] = "--fail";
    argv[n++] = "--silent";
    argv[n++] = "--show-error";
    argv[n++] = "--upload-file";
    argv[n++] = "/var/lib/etcd/mjolnir-snapshot.db";
    argv[n++] = url;
    argv[n++] = NULL;
    run(argv);

    write_file("/var/lib/mjolnir/etcd-snapshot.ok", "ok\n", 0600);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "reset"))
        return cmd_reset(parse_scope(argv[2]));
    if (argc == 3 && !strcmp(argv[1], "reset-preflight"))
        return cmd_reset_preflight(parse_scope(argv[2]));
    if (argc == 2 && !strcmp(argv[1], "snapshot-etcd"))
        return cmd_snapshot();
    if (argc != 2) {
        fprintf(stderr, "usage: mjolnir-helper <init|join|wifi|apply|wait-api|reboot|snapshot-etcd>\n");
        fprintf(stderr, "       mjolnir-helper <reset|reset-preflight> <node-identity|etcd-data|full>\n");
        return 2;
    }
    if (!strcmp(argv[1], "init"))       return cmd_init();
    if (!strcmp(argv[1], "join"))       return cmd_join();
    if (!strcmp(argv[1], "wifi"))       return cmd_wifi();
    if (!strcmp(argv[1], "apply"))      return cmd_apply();
    if (!strcmp(argv[1], "wait-api"))   return cmd_wait_api();
    if (!strcmp(argv[1], "reboot"))     return cmd_reboot();
    fprintf(stderr, "mjolnir-helper: unknown command %s\n", argv[1]);
    return 2;
}
