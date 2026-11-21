# Vendored dracut modules for the live installer ISO

These modules provide dracut's `root=live:CDLABEL=...` support. They are **not**
used in the Mjolnir bootc image — only to build the installer ISO's initramfs
inside the throwaway bootc container in `installer/build-iso.sh`.

## Provenance

- Upstream package: Fedora 43 `dracut-live-107-8.fc43.x86_64.rpm`
  (matches the dracut version shipped in the pinned `fedora-bootc` base image).
- Package source: Fedora 43 Everything / Updates repositories.
- SHA-256 of the RPM these files were extracted from:

  ```
  df1407afb9161b14f8e526c4a386f9061067f4f5f63bb05e578281ca9280d997
  ```

- License: GPL-2.0-or-later / LGPL-2.1-or-later / GPL-2.0-only (per the
  upstream `dracut-live` package). Keep this notice with the vendored files.

To refresh, download the version-matched `dracut-live` RPM, verify the digest
above (or update it deliberately), and replace the two module directories.
