# Automated element updates

BuildStream elements use pinned git refs and sha256 hashes, so Renovate cannot
update them the way it updates a Go module or a GitHub Action: a raw sha256 has
no datasource that knows "the latest hash." Updates therefore work in two
halves.

## What Renovate does

`renovate.json` handles everything with a real datasource:

- `gomod` — the static installer's Go module
- `github-actions` — SHA-pinned action refs
- `custom.regex` managers for the **version keys** in `include/versions.yml`:
  Kubernetes, cri-tools, containerd, runc, CNI plugins (GitHub releases) and
  the kured image digest (Docker registry)

When a version key changes, Renovate opens a PR. It does **not** change the
matching sha256 values — those are recomputed by the workflow below.

## What recomputes the pins

`scripts/update_pins.py` is the source of truth for dependent hashes and refs:

- Downloads each Kubernetes/cri-tools/containerd/runc/CNI asset and computes
  its sha256 for both amd64 and arm64.
- Resolves the FSDK, bootc and BuildStream-plugins git refs via `git ls-remote`
  and emits BuildStream's `<tag>-0-g<sha>` form.
- By default only same-major (patch/minor) git ref bumps are applied. Pass
  `--allow-major` to opt into a major bump.
- `--check` exits 1 when pins would change (useful in CI).

Run it locally:

```sh
python3 scripts/update_pins.py --check   # verify pins are current
python3 scripts/update_pins.py           # rewrite include/versions.yml and .bst refs
```

## Scheduled workflow

`.github/workflows/update-elements.yml` runs weekly (Monday 04:17 UTC) and on
demand with `allow_major`. It runs `scripts/update_pins.py` and opens/updates a
PR via `peter-evans/create-pull-request`. The normal image CI then rebuilds and
validates the PR. Patch/minor updates auto-merge once CI is green; majors need
manual review.

## Important caveat

A git tag can be force-moved upstream. When that happens `update_pins.py`
reports a changed ref even though the version is unchanged (we saw this with
FSDK `26.08.4`). Review those diffs carefully: a moved tag means upstream
rebuilt the same version, and the image content will change.

## Audit

Every pin is still verified by BuildStream at build time. The script only
produces candidates for review; it never bypasses the signature/digest checks
in `elements/k8s/binaries-src.bst` or `tests/test_pins.py`.
