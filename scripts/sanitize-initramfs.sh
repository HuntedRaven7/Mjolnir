#!/usr/bin/env bash
# Remove every interpreter from a generated dracut initramfs.
#
# Build-time only. Dracut ships a systemd initrd with shell hooks even when
# none of them are on the boot path. Hard rule 1 covers boot artifacts, so the
# shipped image must not carry them. The compiled systemd units and bootc's
# initramfs-setup stay; only shells, shebang payloads and the units that run
# them are removed.
set -euo pipefail

input=${1:?usage: sanitize-initramfs.sh INPUT OUTPUT}
output=${2:?usage: sanitize-initramfs.sh INPUT OUTPUT}
[ -f "$input" ] || { echo "no such initramfs: $input" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Dracut concatenates an uncompressed early-microcode cpio before the zstd
# frame. Keep those bytes verbatim so microcode updates still reach the kernel.
magic=$(printf '\x28\xb5\x2f\xfd')
offset=$(LC_ALL=C grep -abo -m1 "$magic" "$input" | cut -d: -f1 || true)
[ -n "$offset" ] || { echo "no zstd frame in $input" >&2; exit 1; }
head -c "$offset" "$input" > "$work/prefix.bin"
tail -c "+$((offset + 1))" "$input" > "$work/frame.zst"

mkdir "$work/tree"
zstd -q -d -c "$work/frame.zst" | \
  ( cd "$work/tree" && cpio -idmu --quiet --no-absolute-filenames )

tree=$work/tree
removed=0

# Same rule as tests/interpreter_policy.py: interpreter basenames are forbidden
# whether they are ELF files or symlinks, and any regular file starting with
# #! is an interpreter script.
while IFS= read -r -d '' entry; do
  name=${entry##*/}
  case "$name" in
    sh|bash|dash|zsh|fish|python|python[0-9]*|perl|perl[0-9]*|ruby|lua|node|php|tcl|guile|awk|gawk|*.sh)
      rm -f "$entry"
      removed=$((removed + 1))
      ;;
  esac
done < <(find "$tree" \( -type f -o -type l \) -print0)

while IFS= read -r -d '' entry; do
  if [ -f "$entry" ] && [ ! -L "$entry" ] && head -c 2 "$entry" | grep -q '^#!'; then
    rm -f "$entry"
    removed=$((removed + 1))
  fi
done < <(find "$tree" -type f -print0)

# Hook directories only hold shell fragments; no compiled unit reads them.
rm -rf "$tree/var/lib/dracut/hooks"

# Dracut's hook services and the debug/rescue shells ExecStart the files just
# removed. Drop the units; systemd drops the wants/requires links below.
for unit in "$tree"/usr/lib/systemd/system/*.service \
            "$tree"/etc/systemd/system/*.service; do
  [ -f "$unit" ] || continue
  if grep -qE '^ExecStart.*(/bin/sh|/usr/bin/sh|dracut-|/usr/bin/bash)' "$unit"; then
    rm -f "$unit"
    removed=$((removed + 1))
  fi
done

# Remove links whose target no longer exists. Resolve absolute targets against
# the extracted tree so valid links into /usr are kept.
while IFS= read -r -d '' link; do
  target=$(readlink "$link")
  case "$target" in
    /*) candidate="$tree$target" ;;
    *)  candidate="$(dirname "$link")/$target" ;;
  esac
  [ -e "$candidate" ] || rm -f "$link"
done < <(find "$tree" -type l -print0)

# Fail loudly if a future dracut introduces a payload the rules above miss.
while IFS= read -r -d '' entry; do
  name=${entry##*/}
  case "$name" in
    sh|bash|dash|zsh|fish|python|python[0-9]*|perl|perl[0-9]*|ruby|lua|node|php|tcl|guile|awk|gawk|*.sh)
      echo "shell survived sanitizer: $entry" >&2; exit 1 ;;
  esac
  if [ -f "$entry" ] && [ ! -L "$entry" ] && head -c 2 "$entry" | grep -q '^#!'; then
    echo "shebang survived sanitizer: $entry" >&2; exit 1
  fi
done < <(find "$tree" \( -type f -o -type l \) -print0)

# Rebuild the archive with stable ownership and order.
( cd "$tree" && find . -print0 | LC_ALL=C sort -z | \
    cpio --null -o -H newc --quiet --owner=0:0 --numeric-uid-gid ) \
  | zstd -q -19 -f -o "$work/clean.zst"
cat "$work/prefix.bin" "$work/clean.zst" > "$output"

echo "sanitized initramfs: removed $removed interpreter payloads"
