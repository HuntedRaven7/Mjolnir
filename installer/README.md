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
IMAGE=ghcr.io/HuntedRaven7/Mjolnir:latest ./installer/build-iso.sh
```

Output: `dist/mjolnir-installer-amd64.iso` (set `ARCH=arm64` for aarch64).

## Interactive use

Boot the ISO. `mjolnir-installer.service` starts the installer on `/dev/console`.
It prompts for:

- image reference (default `ghcr.io/HuntedRaven7/Mjolnir:latest`)
- WiFi SSID and WPA PSK (optional; writes a NetworkManager keyfile)
- private registry user/token (optional; piped to `podman login`)
- node role (`control-plane` or `worker`)
- target disk (selected from `lsblk`)

It then wipes the disk, pulls the image and runs `bootc install to-disk`.
Wired networking and DHCP are handled by NetworkManager in the live image.

## Headless use

Pass `--config <file>` to skip prompts for values set in the JSON:

```json
{
  "image": "ghcr.io/HuntedRaven7/Mjolnir:latest",
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

`--dry-run` prints the commands without executing them; `--version` prints the
installer version.

## Provisioning the installed node

The installer does not bake credentials into the disk. Pass `role`,
`fleet-kubeconfig`, `wifi-ssid`, `wifi-psk` and the Varlink client CA as systemd
credentials on first boot (see `docs/PROVISIONING.md`). The `hostname` and
`timezone` fields in the config are applied by first-boot provisioning.

## Security notes

- Registry tokens are read from the config and piped to `podman login`; they
  are never written to disk by the installer.
- All external commands are executed as argv via `runner`; there is no
  `sh -c` and no shell in the target image.
- The ISO is UEFI-only (systemd-boot + BLS entries).
