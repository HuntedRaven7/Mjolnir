kind: script
description: |
  Final Mjolnir root filesystem, before the signed UKI is added. Shared by
  oci/mjolnir.bst (which builds the OCI) and uki/mjolnir-uki.bst (which must
  compute the composefs digest of this exact tree). Kept as a single element so
  the digester and the image cannot drift apart.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:components/systemd.bst
- freedesktop-sdk.bst:components/libcap.bst
- filename: oci/layers/mjolnir.bst
  config:
    location: /layer

variables:
  strip-binaries: ''
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
    # Note: helper scripts shipped by systemd/dracut carry `#!/bin/sh` shebangs.
    # They cannot actually run because /bin/sh is removed above; the authoritative
    # enforcement is tests/test_image_contents.py (no shell/interpreter binaries).
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

    # systemd-sysusers may lock these down to 0000; make them readable so the
    # artifact copy (and later OCI layer build) can include them.
    chmod 0640 "${root}/etc/shadow" "${root}/etc/gshadow" 2>/dev/null || true
    cp -a "${root}/." "%{install-root}/"
