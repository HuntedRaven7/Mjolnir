kind: manual
description: |
  Pinned varlink-httpd binary (compiled from an upstream commit) and its units.

build-depends:
- base/sandbox-tools.bst

variables:
  strip-binaries: ''

sources:
- kind: local
  path: 'files/varlink/varlink-httpd-%{go-arch}'
  directory: varlink-httpd
- kind: local
  path: files/varlink/units
  directory: units

config:
  install-commands:
  - |
    set -eu
    d="%{install-root}"
    mkdir -p "${d}"
    if [ -d varlink-httpd ]; then
      cp -a varlink-httpd/. "${d}/"
    else
      cp varlink-httpd "${d}/"
    fi
    if [ ! -f "${d}/varlink-httpd" ]; then
      src=$(find "${d}" -maxdepth 1 -type f | head -n1)
      test -n "${src}"
      mv "${src}" "${d}/varlink-httpd"
    fi
    cp -a units "${d}/units"
