# Security features

## Interpreter policy

The "no shell / no interpreter" rule is enforced at three layers by
`tests/interpreter_policy.py`: file contents in the exported rootfs (shebangs
and ELF `DT_NEEDED` links to interpreter libraries), the BuildStream runtime
graph of `base/os-stack.bst`, and every shipped systemd unit plus the sysusers
shell configuration. Build-only dependencies such as `bash` in
`base/sandbox-tools.bst` are allowed. Intentional exceptions live in
[`tests/interpreter-allowlist.json`](../tests/interpreter-allowlist.json); each
entry needs a reason and a PR/issue reference, so adding one is a reviewable
change rather than a silent carve-out.

## SBOM (software bill of materials)

Mjolnir publishes an **SPDX 2.3 SBOM generated from the BuildStream source
graph** (`just sbom`), using `buildstream-sbom` pinned by commit in
`include/versions.yml`. This captures junctioned FSDK sources that a post-build
syft scan cannot see. The SBOM is uploaded as a CI artifact and can be attached
to the image as an OCI referrer with `oras attach`.

Verify a published image with `scripts/verify-image.sh IMAGE DIGEST`:
- keyless `cosign verify` with our workflow identity
- legacy `.sig` tag presence (bootc/podman compatibility)
- SPDX v2.3 attestation when available

`sign-and-publish@v1` is configured with `generate-sbom: false`, signs the
immutable digest pushed by the build, and uses an explicit
`certificate-identity-regexp` because its default regexp only matches
projectbluefin orgs.

Promotion to `:stable` **re-verifies** the signature and SPDX attestation on
that exact digest before mutating the tag (see `docs/RELEASING.md`). An
unsigned or unattested `:testing` image can never become `:stable`.

## Sealed boot (signed UKI + composefs)

Mjolnir builds a **signed, sealed Unified Kernel Image (UKI)** using
`bootc container ukify` (see `elements/uki/mjolnir-uki.bst`):

- The kernel and initramfs come from `kernel/initramfs.bst` and are embedded in
  the UKI. They are not moved out of the tree being hashed.
- `bootc container ukify` computes the **composefs digest of the final rootfs**
  (`oci/rootfs.bst`, including the signed systemd-boot loader) and bakes it into
  the signed `.cmdline` section (`composefs.digest=v1-sha512-12:…` plus the
  legacy `composefs=…` fallback). Our `kargs.d` entries, including
  `systemd.volatile=yes` and `console=ttyS0`, are baked in too — no `--karg` is
  allowed at install time because that would be unsigned.
- The UKI is signed with `systemd-sbsign` (reproducible: uses `SOURCE_DATE_EPOCH`)
  and verified with `sbverify`. systemd-boot is signed in the signing-only
  `uki/systemd-boot.bst` element, so it is already part of the hashed rootfs.
- `bootc install to-disk --composefs-backend --bootloader systemd` detects the
  UKI at `/boot/EFI/Linux/`, regenerates the composefs digest from the final OCI
  rootfs, and refuses to install unless the two agree. The digest, not a mutable
  path, is the root of trust. `testsuite/boot/test-boot.sh` runs this install and
  a subsequent OVMF boot on every pull request.
- Keys are never committed. `files/boot-keys/` is gitignored; CI writes the real
  DB/PK/KEK keys from secrets before release builds. Dev builds generate
  throwaway keys at build time via `scripts/gen-dev-keys.sh` (or on demand in the
  `uki/boot-keys.bst` element). Signing elements are never in a runtime stack,
  because their BST artifacts contain key material.

### Debug UKI

A second UKI is built from the same rootfs and therefore pins the same verified
root. It is signed by a **distinct DEBUG key pair** that is generated in
`uki/boot-keys.bst` and is never enrolled in production firmware. It has its own
filename (`mjolnir-debug-<kver>.efi`) and a `Mjolnir (debug)` title, and is staged under
`/boot/mjolnir-debug`. It is not an enabled layer or a bootc-managed deployment:
bootc rejects a second composefs cmdline under `/boot/EFI/Linux` and names all
of the UKIs it installs after the deployment digest. Provisioning copies the
debug binary and its `mjolnir-debug.conf` onto the ESP only when a debug entry
is wanted; the default image always boots the DB/VENDOR-signed UKI.

For downstream unlock tests, Mjolnir also publishes an OVMF variable store
enrolling both `VENDOR.crt` and `DEBUG.crt`, the production UKI, and a UKI
signed by DEBUG with a separate PCR key. Their stable URLs and regeneration
steps are in [docs/SECUREBOOT-FIXTURES.md](SECUREBOOT-FIXTURES.md). Only public
key material is published.

The `mjolnir.boot-report` systemd credential is opt-in and prints `bootc status`
JSON on the serial console. CI uses it to assert bootc status and image
provenance without a shell in the image.

On real hardware you must enroll the DB key in firmware (setup mode via
`loader/keys/auto/`, or shim/MOK). The image alone cannot enroll keys for you —
that is deliberately an out-of-band, physically local step.

## Measured boot attestation

`mjolnir-fleet` produces an opportunistic attestation report
(`io.mjolnir.Fleet.Attestation`) and includes it in `MjolnirNode.status.attestation`:

- SHA-256 PCR values from `/sys/class/tpm/tpm0/pcr-sha256/*` when a TPM is present
- SHA-256 hash of the binary TCG event log
- SHA-256 hashes of every signed UKI discovered on the ESP, with the default
  bootc-managed entry (`EFI/Linux/bootc/bootc_composefs-*.efi`) preferred for
  the flat `uki.peHashSha256` field. The `uki.candidates` array also reports the
  opt-in debug entry, so attestation never assumes a single `.efi` on the ESP.
- the pinned composefs digest parsed from `/proc/cmdline`
  (`composefs.digest=v1-sha512-12:…`, with a `composefs=` fallback) — this is a
  SHA-512 digest, not a dm-verity root hash; the legacy field name is kept for
  CRD compatibility
- boot ID and machine ID

**This is evidence, not a hardware-backed proof.** Full `TPM2_Quote` with a
provisioned attestation key is deferred; the fleet controller decides the
`verified` field. No TPM is required — the report falls back to software mode.
No shell or interpreter is used in the image.

### Verifying a report

`scripts/verify-attestation.py` runs on the verifier host, never on the node.
It compares a report with the pinned values for the release and prints a JSON
verdict; `--patch-node` writes that verdict to `status.attestation.verified`
via `kubectl`:

```sh
python3 scripts/verify-attestation.py --report report.json \
  --expect-composefs "$COMPOSEFS_DIGEST" \
  --expect-uki-pe "$UKI_PE_SHA256" \
  --expect-image-digest "$IMAGE_DIGEST" \
  --expect-pcr11 "$PCR11" --expect-method tpm2 \
  --patch-node mjolnir-1
```

The script exits non-zero when the verdict is false. Supplying no expectations
still validates the report shape and method. The node never sets `verified`;
the CRD schema allows that field only for the verifier.

## Encrypted state and signed PCR 11 policy

`MjolnirState` is a LUKS2 partition created by `systemd-repart` with an empty
first-boot slot. `mjolnir-state-enroll.service` replaces that slot with a TPM2
enrollment bound to **PCR 7** (Secure Boot state) and a **signed PCR 11
policy**. Enrollment uses `systemd-cryptenroll` and fails closed when the
signature or public key from the signed UKI is absent.

The PCR signing key is generated or injected only in the signing-only
`uki/boot-keys.bst` artifact. `ukify` embeds the `.pcrsig` signature and
`.pcrpkey` public key in each signed UKI; `systemd-stub` exposes them to the
initrd, so a UKI upgrade keeps unsealing the state without re-enrollment. Only
public key material is published. No key is stored in the repository or in the
runtime image's configuration.

The initramfs is built with the dracut `crypt` module and the systemd TPM2
cryptsetup token plugin, whose ELF dependencies pull in `tpm2-tss`. It includes
the build-time `/etc/crypttab`.

## Factory reset

`io.mjolnir.Fleet.FactoryReset` requires a `scope`
(`node-identity`, `etcd-data`, `full`) and an exact confirmation string
`factory-reset:<scope>`. `io.mjolnir.Fleet.ResetPreflight` reports readiness
without changing state; `io.mjolnir.Fleet.SnapshotNow` starts the snapshot unit.

The scoped helper (`mjolnir-helper reset <scope>`) is a fail-closed state
machine. It requires a TPM2-sealed `reset-confirm` credential matching the
scope, discovers the control-plane topology, and only then cordons and drains
the node with `kubectl` before removing an explicit path allowlist:

- `node-identity`: kubelet configs and certs, the state partition's
  `/etc/machine-id` and WiFi profiles (the bind-mount sources, not the mounts).
- `etcd-data`: `/var/lib/etcd`, its persistent backing store, and control-plane
  PKI plus kubeadm kubeconfigs.
- `full`: both of the above, then `mjolnir-factory-reset.target`; systemd-repart
  deletes and recreates the state partition on the reset boot.

On a lone control plane, `etcd-data` and `full` additionally require a second
sealed credential and a snapshot uploaded off-node within the last 24 hours.
On multiple control planes the node's etcd member is removed from the quorum
before its data is wiped. The stock `factory-reset.target` asks for physical
confirmation to clear EFI/TPM, so our target omits those units for headless
operation.

After a reset the controller must re-provision credentials and rotate the
machine-id. The helper drains through `kubectl`, not kured's sentinel, so a
reset does not race a staged bootc update.

## Reproducibility

`just repro` builds `oci/mjolnir.bst` twice from scratch and compares the
BuildStream artifact CAS digest and a hash of the complete OCI layout. Both must
match. This is a weekly CI check.

## Golden image diff

On every push to `testing`, `build.yml` emits a `/usr` file-list diff between
the previously published `:testing` image and the new build
(`scripts/image-diff.sh`, run before the push so the old image is still the
baseline). It is written to the job summary and uploaded as the
`mjolnir-image-diff` artifact. It does not run on pull requests. Volatile paths
(`machine-id`, `resolv.conf`, logs, `run`, whiteouts) are excluded.
