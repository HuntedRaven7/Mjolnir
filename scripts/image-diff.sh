#!/usr/bin/env bash
# Produce a readable /usr file-list diff between the published image and the
# locally built one, for PR comments. Never executes code from either image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLD="${1:-ghcr.io/HuntedRaven7/Mjolnir:testing}"
NEW="${2:-localhost/mjolnir:latest}"
OUT="${3:-pr-comment.md}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

podman pull -q "$OLD" >/dev/null 2>&1 || true
for pair in "old:$OLD" "new:$NEW"; do
  name=${pair%%:*}; ref=${pair#*:}
  cid=$(podman create --pull=never "$ref")
  podman export "$cid" > "$WORK/$name.tar"
  podman rm -f "$cid" >/dev/null
  tar -tf "$WORK/$name.tar" \
    | sed -e 's#^./##' \
    | grep -Ev '^(proc|sys|dev)(/|$)' \
    | grep -Ev '(^|/)\.wh\..*$' \
    | grep -Ev '(^|/)(machine-id|resolv.conf|hosts|hostname)$' \
    | grep -Ev '^var/log/|^run/|^var/cache/ldconfig/' \
    | sort -u > "$WORK/$name.files"
done

{
  echo '<!-- mjolnir-image-diff -->'
  echo "### /usr file-list diff (published → this PR)"
  echo "Files: old=$(wc -l < "$WORK/old.files") new=$(wc -l < "$WORK/new.files")"
  echo ''
  echo '<details><summary>Removed files</summary>'
  echo ''; echo '```diff'
  comm -23 "$WORK/old.files" "$WORK/new.files" | sed 's/^/- /' | head -200
  echo '```'; echo '</details>'
  echo '<details><summary>Added files</summary>'
  echo ''; echo '```diff'
  comm -13 "$WORK/old.files" "$WORK/new.files" | sed 's/^+/+ /' | head -200
  echo '```'; echo '</details>'
} > "$OUT"

# Cap at 60 kB (GitHub comment limit is 65,536 chars).
if [ "$(wc -c < "$OUT")" -gt 60000 ]; then
  head -c 60000 "$OUT" > "$OUT.trim"
  printf '\n\n_Truncated at 60 kB._\n' >> "$OUT.trim"
  mv "$OUT.trim" "$OUT"
fi
cat "$OUT" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "wrote $OUT"
