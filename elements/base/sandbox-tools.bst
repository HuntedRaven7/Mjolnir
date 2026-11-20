kind: stack
description: |
  Shell and core utilities for Mjolnir's own build sandboxes only. This stack
  is never added to the shipped layer: FSDK 26.08's runtime-minimal has no
  shell, and every element that runs commands build-depends on this stack.

depends:
- freedesktop-sdk.bst:bootstrap/bash.bst
- freedesktop-sdk.bst:bootstrap/coreutils.bst
- freedesktop-sdk.bst:components/gcc-libs.bst
- freedesktop-sdk.bst:components/sed.bst
- freedesktop-sdk.bst:components/findutils.bst
- freedesktop-sdk.bst:components/tar.bst
- freedesktop-sdk.bst:components/gzip.bst
- freedesktop-sdk.bst:components/xz.bst
