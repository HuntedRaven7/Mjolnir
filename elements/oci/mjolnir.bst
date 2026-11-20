kind: script
description: |
  Final Mjolnir bootc OCI image. The composition is sanitized (no shell,
  SSH daemon or language interpreter, no SUID/SGID, no file capabilities)
  before build-oci turns it into an OCI layout with bootc labels.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:components/oci-builder.bst
- freedesktop-sdk.bst:components/libcap.bst
- filename: oci/layers/mjolnir.bst
  config:
    location: /layer

variables:
  strip-binaries: ''
  image-repo: mjolnir
  sysroot-seed: 2b6e2ba0-6f4a-4d32-9a08-6f0f0f0f0f01

config:
  commands:
  - |
    set -eu
    root=/layer

    # --- identity -----------------------------------------------------------
    mkdir -p "${root}/usr/lib" "${root}/etc"
    cat > "${root}/usr/lib/os-release" <<'EOF'
    NAME="Mjolnir"
    PRETTY_NAME="Mjolnir (FSDK bootc server)"
    ID=mjolnir
    ID_LIKE="fedoraproject"
    ANSI_COLOR="1;34"
    HOME_URL="https://github.com/quinn/Mjolnir"
    BUG_REPORT_URL="https://github.com/quinn/Mjolnir/issues"
    VERSION_ID="0"
    IMAGE_VERSION="0"
    VARIANT_ID="server"
    EOF
    ln -sf ../usr/lib/os-release "${root}/etc/os-release"

    # --- no shell / no SSH / no interpreters --------------------------------
    for f in \
      bin/sh usr/bin/sh bin/bash usr/bin/bash usr/bin/dash \
      usr/bin/rbash usr/bin/zsh usr/bin/fish usr/bin/csh usr/bin/tcsh \
      usr/bin/python usr/bin/python2 usr/bin/python3 usr/bin/perl usr/bin/perl5 \
      usr/bin/ruby usr/bin/node usr/bin/php usr/bin/lua usr/bin/awk usr/bin/gawk \
      usr/bin/ssh usr/bin/sshd usr/bin/scp usr/bin/sftp usr/bin/ssh-keygen \
      usr/bin/ssh-keyscan usr/bin/sftp-server \
      usr/bin/login usr/bin/agetty usr/bin/su usr/bin/sulogin \
      etc/pam.d/sshd; do
      rm -f "${root}/${f}"
    done
    find "${root}" -type f -name 'python3*' -delete 2>/dev/null || true
    find "${root}" -type f -name 'perl*' -delete 2>/dev/null || true
    find "${root}" -type f -name '*.py' -delete 2>/dev/null || true
    find "${root}" -type f -name '*.pl' -delete 2>/dev/null || true
    # Any remaining interpreter shebang is a policy violation. Report it so
    # the element can be fixed rather than silently shipping a script.
    if find "${root}/usr" -type f -perm /111 \
        -exec grep -Il '^#!.*\(/bin/sh\|/bin/bash\|python\|perl\)' {} + 2>/dev/null \
        | tee /tmp/mjolnir-shebangs | grep -q .; then
      echo "ERROR: interpreter shebangs found in the image" >&2
      exit 1
    fi
    rm -rf "${root}/usr/lib/python3"* "${root}/usr/lib/perl5"* \
           "${root}/usr/libexec/openssh" "${root}/etc/ssh" 2>/dev/null || true
    find "${root}/usr/share/man" \( -type f -o -type l \) \
      \( -name 'python3*' -o -name 'perl*' \) -delete 2>/dev/null || true
    rm -rf "${root}/usr/share/licenses/freedesktop-sdk/python3"* \
           "${root}/usr/share/licenses/freedesktop-sdk/perl"* 2>/dev/null || true

    # --- no SUID/SGID or file capabilities ----------------------------------
    find "${root}" -xdev \( -type f -o -type d \) -perm /6000 -exec chmod a-s {} +
    find "${root}" -xdev -type f -exec setcap -r {} + 2>/dev/null || true

    # --- bootc / sysroot hygiene --------------------------------------------
    if [ -d "${root}/usr/etc" ]; then
      mkdir -p "${root}/etc"
      cp -a "${root}/usr/etc/." "${root}/etc/"
      rm -rf "${root}/usr/etc"
    fi
    systemd-sysusers --root "${root}" || true
    : > "${root}/etc/machine-id"

    # Must be the last post-install step (dakota PR #497 regression).
    ldconfig -r "${root}" -f "${root}/etc/ld.so.conf" || true

    # --- build the OCI layout -----------------------------------------------
    cd "%{install-root}"
    build-oci <<'EOF'
    mode: oci
    gzip: disabled
    images:
    - os: linux
      architecture: "%{go-arch}"
      layer: /layer
      comment: "Import Mjolnir layer"
      config:
        Labels:
          'containers.bootc': '1'
          'org.opencontainers.image.title': 'Mjolnir'
          'org.opencontainers.image.description': 'FSDK-based hardened Kubernetes server'
          'org.opencontainers.image.vendor': 'Mjolnir'
          'org.opencontainers.image.licenses': 'Apache-2.0'
      index-annotations:
        'org.opencontainers.image.ref.name': 'ghcr.io/quinn/mjolnir:%{branch}'
    EOF
