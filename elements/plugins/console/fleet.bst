kind: script
description: |
  Compiled fleet exporter and Varlink action service. Uses json-c for the
  Varlink JSON protocol and libsystemd for socket activation.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst
- freedesktop-sdk.bst:components/gcc.bst
- freedesktop-sdk.bst:components/json-c.bst
- freedesktop-sdk.bst:components/systemd.bst
- filename: plugins/console/fleet-src.bst
  config:
    location: /src

variables:
  strip-binaries: ''

config:
  commands:
  - |
    set -eu
    cd /src
    make
    make install DESTDIR="%{install-root}"
