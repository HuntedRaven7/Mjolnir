kind: script
description: |
  Installs the Varlink-over-HTTPS management bridge.

build-depends:
- base/sandbox-tools.bst
- filename: mgmt/varlink-src.bst
  config:
    location: /src

config:
  commands:
  - |
    set -eu
    root="%{install-root}"
    install -Dm755 /src/varlink-httpd "${root}/usr/bin/varlink-httpd"
    mkdir -p "${root}/usr/lib/systemd/system"
    cp /src/units/*.service /src/units/*.socket "${root}/usr/lib/systemd/system/"
