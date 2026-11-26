# Mjolnir build tasks. BuildStream runs inside the pinned FSDK bst2 container;
# BST is not installed on the host.

podman := env("PODMAN", "podman")
image_name := env("BUILD_IMAGE_NAME", "mjolnir")
image_tag := env("BUILD_IMAGE_TAG", "latest")
bst2_image := env("BST2_IMAGE", "registry.gitlab.com/freedesktop-sdk/infrastructure/freedesktop-sdk-docker-images/bst2:64eb0b4930d57a92710822898fb73af6cc1ae35d")
registry := env("IMAGE_REGISTRY", "ghcr.io/quinn")

# Run any bst command inside the bst2 container.
bst *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "${HOME}/.cache/buildstream" .build-out
    podman run --rm --privileged --device /dev/fuse --network=host \
      -v "{{justfile_directory()}}:/src:rw" \
      -v "${HOME}/.cache/buildstream:/root/.cache/buildstream:rw" \
      -w /src "{{bst2_image}}" \
      bash -c 'bst --colors "$@"' -- --no-interactive {{ARGS}}

# Move the BuildStream cache to/from a GHCR OCI artifact. The cache dir is the
# same one `bst` bind-mounts into the bst2 container, so restoring it here warms
# every subsequent bst invocation. Failures are non-fatal by design.
cache-pull:
    scripts/bst-cache-oci.sh pull

cache-push:
    scripts/bst-cache-oci.sh push

# Validate the element graph without building.
validate:
    just bst show oci/mjolnir.bst

# Build the final OCI element.
bst-build:
    just bst build oci/mjolnir.bst

# Checkout the OCI layout and load it into podman. The image intentionally has
# no shell, so the export step does not use a Dockerfile `RUN`.
export arch="x86_64":
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf .build-out
    just bst -o arch "{{arch}}" artifact checkout oci/mjolnir.bst --directory /src/.build-out
    IMAGE_ID=$({{podman}} pull -q oci:.build-out)
    {{podman}} tag "$IMAGE_ID" "{{image_name}}:{{image_tag}}"
    {{podman}} images | grep -E '{{image_name}}|REPOSITORY' || true

# Generate an SPDX 2.3 SBOM from the BuildStream source graph (dakota-style).
# buildstream-sbom reads the BST element graph, so it captures junctioned FSDK
# sources that a post-build syft scan cannot see.
sbom:
    #!/usr/bin/env bash
    set -euo pipefail
    REF=$(grep 'buildstream-sbom-ref' include/versions.yml | sed -E 's/.*"(.*)"/\1/')
    python3 -m pip install --quiet --user "git+https://gitlab.com/BuildStream/buildstream-sbom.git@${REF}"
    ELEMENT=oci/mjolnir.bst
    SPDX_NAME=mjolnir
    NAMESPACE="https://github.com/HuntedRaven7/Mjolnir/sbom/$(git rev-parse HEAD)"
    mkdir -p sbom_out
    just bst show "$ELEMENT" --deps all >/dev/null
    ~/.local/bin/buildstream-sbom "$ELEMENT" \
      --spdx-name "${SPDX_NAME}" \
      --spdx-namespace "${NAMESPACE}" \
      --spdx-creator "Tool: buildstream-sbom" \
      --spdx-creator "Organization: Mjolnir" \
      --deps all \
      --output /src/sbom_out/mjolnir.spdx.json
    echo "wrote sbom_out/mjolnir.spdx.json"

# Full local build.
build: bst-build export

# bootc structural validation.
lint:
    {{podman}} run --rm --privileged "{{image_name}}:{{image_tag}}" bootc container lint

# Content assertions (no shell/interpreter, no SUID, pinned manifests).
test:
    python3 tests/test_units.py
    python3 tests/test_member_id.py
    python3 tests/test_diagnostics.py
    python3 tests/test_state_reset.py
    python3 tests/test_attestation_verifier.py
    python3 tests/test_fleet_varlink.py
    python3 tests/test_initramfs_policy.py
    python3 tests/test_initramfs_sanitizer.py
    python3 tests/test_update_pins.py
    python3 tests/test_pins.py
    python3 tests/test_image_contents.py "{{image_name}}:{{image_tag}}"
    python3 tests/test_boot_assets.py "{{image_name}}:{{image_tag}}"

# Install the image to a raw disk image via loopback.
disk size="32G":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -e build/bootable.raw ]; then
      mkdir -p build
      fallocate -l {{size}} build/bootable.raw
    fi
    {{podman}} run --rm --privileged --pid=host \
      -v /dev:/dev --tmpfs /run/udev \
      -v /var/lib/containers:/var/lib/containers \
      -v "{{justfile_directory()}}:/data" \
      \
      "{{image_name}}:{{image_tag}}" \
      bootc install to-disk --composefs-backend --via-loopback /data/build/bootable.raw \
        --filesystem btrfs --wipe --bootloader systemd
    # No --karg: a sealed UKI carries its whole cmdline in the signed
    # .cmdline section, and bootc rejects install-time kargs for immutable boot.

# Full install + OVMF boot proof. Requires root, KVM, QEMU and OVMF.
boot-test:
    #!/usr/bin/env bash
    set -euo pipefail
    exec bash "{{justfile_directory()}}/testsuite/boot/test-boot.sh" "{{image_name}}:{{image_tag}}"

# Boot the raw disk image headlessly with a serial console.
vm:
    qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 -cpu host \
      -drive file=build/bootable.raw,format=raw,media=disk \
      -nographic -serial mon:stdio \
      -netdev user,id=net0,hostfwd=tcp::2222-:22 \
      -device virtio-net-pci,netdev=net0

clean:
    rm -rf .build-out build
    {{podman}} rmi "{{image_name}}:{{image_tag}}" || true

# Check host prerequisites for build/test/ISO (read-only).
doctor:
    #!/usr/bin/env bash
    exec bash "{{justfile_directory()}}/scripts/doctor.sh" "{{podman}}" "{{bst2_image}}" "{{justfile_directory()}}"

# Verify the image builds reproducibly (twice, compare digests).
repro:
    ./scripts/repro-check.sh

# Diff the published image against the local build for PR comments.
image-diff old="ghcr.io/huntedraven7/mjolnir:testing" new="localhost/mjolnir:latest" out="pr-comment.md":
    ./scripts/image-diff.sh "{{old}}" "{{new}}" "{{out}}"

# Generate a ready-to-import Console card, auto-detecting the Console origin.
plugin-card:
    chmod +x "{{justfile_directory()}}/scripts/install-console-card.sh"
    "{{justfile_directory()}}/scripts/install-console-card.sh"

# Cut a stable release (dakota-style digest promotion). Dry-run by default:
#   just release                       # preflight only
#   just release --apply               # promote + cut GitHub Release
#   just release --apply sha=<40-char> # recovery: promote a specific commit
release *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    apply=false
    sha=""
    for arg in {{ARGS}}; do
      case "$arg" in
        --apply) apply=true ;;
        sha=*) sha="${arg#sha=}" ;;
        *) echo "usage: just release [--apply] [sha=<40-char-sha>]" >&2; exit 2 ;;
      esac
    done
    if [ -n "$sha" ] && ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "sha must be a full 40-character lowercase SHA" >&2
      exit 2
    fi
    mode="preflight (dry run)"
    [ "$apply" = true ] && mode="APPLY (promote to :stable)"
    echo "mode:      ${mode}"
    echo "repo:      HuntedRaven7/Mjolnir"
    echo "workflow:  execute-release.yml @ testing"
    echo "candidate: ${sha:-testing HEAD}"
    gh workflow run execute-release.yml --ref testing \
      -f dry_run=$([ "$apply" = true ] && echo false || echo true) \
      -f promote_sha="$sha"
    echo "Dispatched. Watch with: gh run watch"
