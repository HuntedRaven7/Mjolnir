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

# Validate the element graph without building.
validate:
    just bst show oci/mjolnir.bst

# Build the final OCI element.
bst-build:
    just bst build oci/mjolnir.bst

# Checkout the OCI layout and load it into podman. The image intentionally has
# no shell, so the export step does not use a Dockerfile `RUN`.
export:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf .build-out
    just bst artifact checkout oci/mjolnir.bst --directory /src/.build-out
    IMAGE_ID=$({{podman}} pull -q oci:.build-out)
    {{podman}} tag "$IMAGE_ID" "{{image_name}}:{{image_tag}}"
    {{podman}} images | grep -E '{{image_name}}|REPOSITORY' || true

# Full local build.
build: bst-build export

# bootc structural validation.
lint:
    {{podman}} run --rm --privileged "{{image_name}}:{{image_tag}}" bootc container lint

# Content assertions (no shell/interpreter, no SUID, pinned manifests).
test:
    python3 tests/test_units.py
    python3 tests/test_installer.py
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
      -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
      -v "{{justfile_directory()}}:/data" \
      \
      "{{image_name}}:{{image_tag}}" \
      bootc install to-disk --via-loopback /data/build/bootable.raw \
        --filesystem btrfs --wipe --bootloader systemd \
        --karg systemd.firstboot=no --karg quiet

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

# Build the minimal live installer ISO (requires xorriso and mtools).
iso:
    ./installer/build-iso.sh
