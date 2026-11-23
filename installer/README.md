# Mjolnir live installer

A small static Go binary plus a minimal UEFI live ISO that installs Mjolnir
from a registry onto a local disk. It is adapted from the architecture of
[projectbluefin/knuckle](https://github.com/projectbluefin/knuckle)
(Apache-2.0): argv-only command execution through a runner, a Bubble Tea/Huh
TUI with a headless JSON fallback, and a squashfs-in-initrd live image assembled
with xorriso. Unlike knuckle, it installs a bootc OCI image directly with
`bootc install to-disk`.

## Build

Host prerequisites: `go`, `podman`, `cpio`, `gzip`, `xz`, `mtools`,
`squashfs-tools`, `xorriso` and systemd-boot EFI binaries.

```sh
IMAGE=ghcr.io/huntedraven7/mjolnir:stable ./installer/build-iso.sh
```

Output: `dist/mjolnir-installer-amd64.iso` (set `ARCH=arm64` for aarch64).

## Interactive use

Boot the ISO. `mjolnir-installer.service` attaches stdin to the console and
starts a full-screen Bubble Tea / Huh TUI. It asks for:

- image reference (default `ghcr.io/huntedraven7/mjolnir:stable`)
- node role (`control-plane` or `worker`), hostname and timezone
- root filesystem (`btrfs`, `ext4` or `xfs`) and optional TPM2/LUKS encryption
- optional WiFi SSID and WPA PSK (writes a NetworkManager keyfile)
- optional private registry user/token (piped to `podman login`)
- target disk, selected from `lsblk`, with a typed confirmation

Removable media, mounted disks and the disk named on the kernel command line
are never offered. Disks smaller than 20 GB are rejected. On a serial console
the installer sets an 80x40 geometry first, because serial TTYs do not
negotiate a window size.

After the form is submitted the TUI exits and the install log streams to the
console. It verifies that the target has a vfat ESP containing systemd-boot and
a signed UKI, plus the chosen root filesystem, before reporting success.

## Headless use

Automation sets `"headless": true` in the installer config (or passes
`--headless`/`--yes`). `HEADLESS=1 ./installer/build-iso.sh` writes that flag
into the ISO config; the e2e harness does this. No TTY is then required.

Pass `--config <file>` to set values without the TUI:

```json
{
  "image": "ghcr.io/huntedraven7/mjolnir:stable",
  "disk": "/dev/vda",
  "role": "worker",
  "hostname": "mjolnir-1",
  "ssid": "my-network",
  "psk": "<64 hex chars>",
  "registryUser": "",
  "registryToken": "",
  "filesystem": "btrfs",
  "encrypted": false,
  "headless": true
}
```

`--yes` selects the configured disk — or the first eligible disk if none is
configured — without a TUI. Set `"encrypted": true` (or pass `--encrypt`) for a
TPM2-bound LUKS root (`bootc install --block-setup tpm2-luks`); the machine must
have a TPM2 device. `--dry-run` prints the commands without executing them;
`--version` prints the installer version.

## Provisioning the installed node

The installer does not bake credentials into the disk. Pass `role`,
`fleet-kubeconfig`, `wifi-ssid`, `wifi-psk` and the Varlink client CA as systemd
credentials on first boot (see `docs/PROVISIONING.md`). The `hostname` and
`timezone` fields in the config are applied by first-boot provisioning.

## Security notes

- Registry tokens are piped to `podman login` via stdin, never passed as an
  argument or written to disk by the installer.
- Prefer **systemd credentials** over config values for secrets. Put
  `registry-user`, `registry-token`, `wifi-ssid` and `wifi-psk` in
  `$CREDENTIALS_DIRECTORY`, `/run/credentials/mjolnir-installer.service/` or
  `/run/credentials/@system/`; the installer reads them and only falls back to
  the JSON config. `wifi-psk` must be exactly 64 hex characters.
- All external commands are executed as argv via `runner`; there is no
  `sh -c` and no shell in the target image.
- The ISO is UEFI-only (systemd-boot + BLS entries).
