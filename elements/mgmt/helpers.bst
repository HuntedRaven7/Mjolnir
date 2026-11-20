kind: script
description: |
  Compiled host helper. No shell or interpreter is involved in any operation.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst
- freedesktop-sdk.bst:components/gcc.bst
- filename: mgmt/helpers-src.bst
  config:
    location: /src

config:
  commands:
  - |
    set -eu
    cd /src
    make
    make install DESTDIR="%{install-root}"
