// SPDX-License-Identifier: Apache-2.0
// Mjolnir host helper. Compiled C: there is no shell or interpreter in the
// image, so all orchestration that would normally be a script lives here.
//
// Usage: mjolnir-helper <init|join|wifi|apply|wait-api|reboot>

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
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
// WiFi client provisioning (iwd)
// ---------------------------------------------------------------------------
static int cmd_wifi(void) {
    char ssid[256] = {0}, psk[256] = {0};
    if (read_credential("wifi-ssid", ssid, sizeof(ssid)) < 0 ||
        read_credential("wifi-psk", psk, sizeof(psk)) < 0) {
        fprintf(stderr, "mjolnir-helper: no WiFi credentials; skipping\n");
        return 0;
    }
    if (strlen(psk) != 64)
        die("wifi-psk must be a 64 character hex string");
    if (mkdir("/var/lib/iwd", 0700) < 0 && errno != EEXIST)
        die("mkdir /var/lib/iwd");
    char path[512], content[512];
    snprintf(path, sizeof(path), "/var/lib/iwd/%s.psk", ssid);
    snprintf(content, sizeof(content), "[Security]\nPassphrase=%s\n", psk);
    write_file(path, content, 0600);
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
    const char *dirs[] = { MANIFEST_DIR "/cilium", MANIFEST_DIR "/kubestellar" };
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
// reboot coordination: only reboot when bootc flagged /run/reboot-required
// and no Kubernetes drain is in progress.
// ---------------------------------------------------------------------------
static int cmd_reboot(void) {
    if (access("/run/reboot-lock", F_OK) == 0 || access("/etc/reboot-lock", F_OK) == 0) {
        fprintf(stderr, "mjolnir-helper: reboot held by lock\n");
        return 0;
    }
    if (access("/run/reboot-required", F_OK) != 0)
        return 0;
    if (access("/run/kubestellar-reboot-deferred", F_OK) == 0)
        return 0;
    const char *argv[] = { "/usr/bin/systemctl", "reboot", NULL };
    run(argv);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: mjolnir-helper <init|join|wifi|apply|wait-api|reboot>\n");
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
