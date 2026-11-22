# Mjolnir live installer

A small static Go binary plus a minimal UEFI live ISO that installs Mjolnir
from a registry onto a local disk. It is adapted from the architecture of
[projectbluefin/knuckle](https://github.com/projectbluefin/knuckle)
(Apache-2.0): argv-only command execution through a runner, a headless JSON
config, and a squashfs-in-initrd live image assembled with xorriso. Unlike
knuckle, it does not use a TUI library and it installs a bootc OCI image
directly with `bootc install to-disk`.

## Build

Host prerequisites: `go`, `podman`, `cpio`, `gzip`, `xz`, `mtools`,
`squashfs-tools`, `xorriso` and systemd-boot EFI binaries.

```sh
IMAGE=ghcr.io/huntedraven7/mjolnir:stable ./installer/build-iso.sh
```

Output: `dist/mjolnir-installer-amd64.iso` (set `ARCH=arm64` for aarch64).

## Interactive use

Boot the ISO. `mjolnir-installer.service` starts the installer and logs to both
the journal and the console. It prompts for:

- image reference (default `ghcr.io/huntedraven7/mjolnir:stable`)
- WiFi SSID and WPA PSK (optional; writes a NetworkManager keyfile)
- private registry user/token (optional; piped to `podman login`)
- node role (`control-plane` or `worker`)
- target disk (selected from `lsblk`)

Removable media, mounted disks and the disk named on the kernel command line
are never offered. The interactive flow requires you to **type the exact disk
path** before anything is erased, and disks smaller than 20 GB are rejected.

After the install it verifies that the target has a vfat ESP containing
systemd-boot and a signed UKI, plus a btrfs root, before reporting success.
Wired networking and DHCP are handled by NetworkManager in the live image.

## Headless use

Pass `--config <file>` to skip prompts for values set in the JSON:

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
  "filesystem": "btrfs"
}
```

`--yes` disables all prompts and selects the configured disk — or the first
eligible disk if none is configured. The service in the ISO uses this flag
because it has no tty; an interactive terminal should omit it to get the disk
confirmation prompt. `--dry-run` prints the commands without executing them;
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
