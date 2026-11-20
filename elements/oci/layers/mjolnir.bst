kind: compose
description: |
  Filesystem payload for the Mjolnir image. devel/debug content is filtered
  out; the result is staged into /layer by oci/mjolnir.bst.

build-depends:
# Build-time shell for FSDK integration commands; stripped from the final
# image by oci/mjolnir.bst and asserted by tests/test_image_contents.py.
- base/sandbox-tools.bst
- base/os-stack.bst

config:
  exclude:
  - devel
  - debug
  - static-blocklist
