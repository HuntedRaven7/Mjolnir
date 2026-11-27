// SPDX-License-Identifier: Apache-2.0
// Opportunistic measured-boot attestation for Mjolnir.
//
// Produces a JSON attestation object without any shell or interpreter:
//   - SHA-256 PCR values from sysfs (when a TPM is present)
//   - SHA-256 hash of the binary TCG event log
//   - UKI PE hash, boot ID, machine ID and the verity root hash from the cmdline
//
// Full TPM2_Quote with a provisioned AK is intentionally deferred: it needs a
// verifier-side trust store. This report is evidence, not a hardware proof; the
// fleet controller decides `verified`.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <json-c/json.h>
#include <openssl/evp.h>

#include "attest.h"

static char *slurp(const char *path, size_t max) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    char *buf = calloc(1, max + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, max, f);
    buf[n] = '\0';
    fclose(f);
    return buf;
}

static char *sha256_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int len = 0;
    if (!ctx || EVP_DigestInit_ex(ctx, EVP_sha256(), 0) != 1) {
        if (ctx) EVP_MD_CTX_free(ctx);
        fclose(f);
        return NULL;
    }
    unsigned char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
        EVP_DigestUpdate(ctx, buf, n);
    EVP_DigestFinal_ex(ctx, md, &len);
    EVP_MD_CTX_free(ctx);
    fclose(f);
    char *out = calloc(1, len * 2 + 1);
    for (unsigned i = 0; i < len; i++)
        sprintf(out + i * 2, "%02x", md[i]);
    return out;
}

static const int PCRS[] = {0, 1, 2, 3, 4, 5, 7, 9, 11, 12, 13, 14, 15};

json_object *mjolnir_attestation(void) {
    json_object *root = json_object_new_object();
    int have_tpm = access("/sys/class/tpm/tpm0/pcr-sha256/0", F_OK) == 0;
    json_object_object_add(root, "method", json_object_new_string(have_tpm ? "tpm2" : "software"));

    char *boot = slurp("/proc/sys/kernel/random/boot_id", 128);
    char *mid = slurp("/etc/machine-id", 128);
    if (boot) { size_t n = strlen(boot); while (n && boot[n-1] == '\n') boot[--n] = '\0'; }
    if (mid) { size_t n = strlen(mid); while (n && mid[n-1] == '\n') mid[--n] = '\0'; }
    json_object_object_add(root, "bootId", json_object_new_string(boot ? boot : ""));
    json_object_object_add(root, "machineId", json_object_new_string(mid ? mid : ""));

    if (have_tpm) {
        json_object *pcrs = json_object_new_object();
        for (size_t i = 0; i < sizeof(PCRS)/sizeof(PCRS[0]); i++) {
            char path[160];
            snprintf(path, sizeof(path), "/sys/class/tpm/tpm0/pcr-sha256/%d", PCRS[i]);
            char *v = slurp(path, 128);
            if (v) { size_t n = strlen(v); while (n && (v[n-1]=='\n'||v[n-1]=='\r')) v[--n] = '\0'; }
            char key[16];
            snprintf(key, sizeof(key), "%d", PCRS[i]);
            json_object_object_add(pcrs, key, json_object_new_string(v ? v : ""));
            free(v);
        }
        json_object_object_add(root, "pcrBank", json_object_new_string("sha256"));
        json_object_object_add(root, "pcrValues", pcrs);

        char *loghash = sha256_file("/sys/kernel/security/tpm0/binary_bios_measurements");
        json_object_object_add(root, "eventLogHashSha256",
                               json_object_new_string(loghash ? loghash : ""));
        free(loghash);
    }

    // UKI PE hash and verity root hash from the booted system.
    // An image may carry more than one signed UKI: bootc installs the default
    // one under EFI/Linux/bootc, while the opt-in debug UKI is a separate
    // systemd-boot entry. Report every candidate and select the default UKI
    // for the flat fields, so consumers keep working without assuming there
    // is exactly one .efi on the ESP.
    json_object *uki = json_object_new_object();
    json_object *candidates = json_object_new_array();
    char *preferred_path = NULL;
    char *preferred_hash = NULL;
    int preferred_is_debug = 0;
    const char *dirs[] = {
        "/efi/EFI/Linux/bootc", "/boot/EFI/Linux/bootc",
        "/boot/efi/EFI/Linux/bootc", "/efi/EFI/Linux",
        "/boot/EFI/Linux", "/boot/efi/EFI/Linux",
    };
    for (size_t d = 0; d < sizeof(dirs)/sizeof(dirs[0]); d++) {
        DIR *dir = opendir(dirs[d]);
        if (!dir) continue;
        struct dirent *e;
        while ((e = readdir(dir))) {
            size_t n = strlen(e->d_name);
            if (n <= 4 || strcmp(e->d_name + n - 4, ".efi")) continue;
            // Addons and the signed loader are not boot entries.
            if (strstr(e->d_name, ".addon.efi") || !strncmp(e->d_name, "systemd-boot", 12))
                continue;
            char path[512];
            snprintf(path, sizeof(path), "%s/%s", dirs[d], e->d_name);
            char *h = sha256_file(path);
            if (!h) continue;
            int is_debug = strstr(e->d_name, "debug") != NULL;
            json_object *c = json_object_new_object();
            json_object_object_add(c, "path", json_object_new_string(path));
            json_object_object_add(c, "peHashSha256", json_object_new_string(h));
            json_object_object_add(c, "debug", json_object_new_boolean(is_debug));
            json_object_array_add(candidates, c);
            if (!preferred_hash || (preferred_is_debug && !is_debug)) {
                free(preferred_hash);
                preferred_hash = h;
                preferred_path = strdup(path);
                preferred_is_debug = is_debug;
            } else {
                free(h);
            }
        }
        closedir(dir);
    }
    json_object_object_add(uki, "candidates", candidates);
    json_object_object_add(uki, "candidateCount",
                           json_object_new_int(json_object_array_length(candidates)));
    if (preferred_hash) {
        json_object_object_add(uki, "peHashSha256", json_object_new_string(preferred_hash));
        json_object_object_add(uki, "path", json_object_new_string(preferred_path));
        free(preferred_hash);
        free(preferred_path);
    }
    json_object_object_add(root, "uki", uki);

    char *cmdline = slurp("/proc/cmdline", 8192);
    const char *verity = "";
    if (cmdline) {
        // bootc v1 writes composefs.digest=v1-sha512-12:<128 hex>, with a
        // legacy `composefs=<hex>` fallback. Strip the optional `?` marker.
        const char *p = strstr(cmdline, "composefs.digest=");
        if (p) {
            p += strlen("composefs.digest=");
        } else {
            p = strstr(cmdline, "composefs=");
            if (p) p += strlen("composefs=");
        }
        if (p) {
            char tmp[160] = {0};
            size_t i = 0;
            while (*p && *p != ' ' && *p != '\n' && i < sizeof(tmp) - 1) {
                if (*p != '?') tmp[i++] = *p;
                p++;
            }
            verity = strdup(tmp);
        }
    }
    json_object_object_add(root, "usrVerityRootHash", json_object_new_string(verity));

    free(boot); free(mid); free(cmdline);
    return root;
}
