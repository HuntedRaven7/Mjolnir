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
matching sha256 values. The Renovate GitHub App cannot run `postUpgradeTasks`
commands, so a separate workflow handles that (see below).

## What recomputes the pins

`scripts/update_pins.py` is the source of truth for dependent hashes and refs:

- Downloads each Kubernetes/cri-tools/containerd/runc/CNI asset and computes
  its sha256 for both amd64 and arm64.
- Resolves the FSDK, bootc and BuildStream-plugins git refs via `git ls-remote`
  and emits BuildStream's `<tag>-0-g<sha>` form.
- Updates the `buildstream-plugins-community` PyPI sdist: bumps the version in
  the element URL and recomputes its sha256 ref from PyPI.
- By default only same-major (patch/minor) git ref bumps are applied. Pass
  `--allow-major` to opt into a major bump.
- `--check` exits 1 when pins would change (useful in CI).
- `--binary-only` recomputes only the binary sha256s and leaves git refs alone.

Run it locally:

```sh
python3 scripts/update_pins.py --check              # verify all pins are current
python3 scripts/update_pins.py --binary-only --check # verify only binary hashes
python3 scripts/update_pins.py                      # rewrite versions.yml and .bst refs
```

## Renovate PR workflow

`.github/workflows/auto-pins.yml` runs on PRs that change `include/versions.yml`.
It calls `scripts/update_pins.py --binary-only` and pushes the recomputed hashes
back to the PR branch, so a Renovate version bump and its sha256 pins land
together. Git-ref bumps are intentionally left to the weekly workflow below.
The workflow only runs for same-repository PRs (the default token cannot push
to forks), and stops after one commit because it checks `git diff --quiet`.

## Scheduled workflow

`.github/workflows/update-elements.yml` runs weekly (Monday 04:17 UTC) and on
demand with `allow_major`. It runs `scripts/update_pins.py` and opens/updates a
PR via `peter-evans/create-pull-request`. The normal image CI then rebuilds and
validates the PR. Patch/minor updates auto-merge once CI is green; majors need
manual review.

**Repository requirement:** the default `GITHUB_TOKEN` may only create PRs when
*Settings → Actions → General → Workflow permissions → Allow GitHub Actions to
create and approve pull requests* is enabled. Without it the workflow pushes
`automation/update-elements` but fails at PR creation with "GitHub Actions is
not permitted to create or approve pull requests". There is no REST/GraphQL
setting for this checkbox; it must be enabled in the UI (or a PAT supplied via
a repository secret and passed to the action).

## Important caveat

A git tag can be force-moved upstream. When that happens `update_pins.py`
reports a changed ref even though the version is unchanged (we saw this with
FSDK `26.08.4`). Review those diffs carefully: a moved tag means upstream
rebuilt the same version, and the image content will change.

## Audit

Every pin is still verified by BuildStream at build time. The script only
produces candidates for review; it never bypasses the signature/digest checks
in `elements/k8s/binaries-src.bst` or `tests/test_pins.py`.
