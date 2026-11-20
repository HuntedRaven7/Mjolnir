# Releasing Mjolnir

Mjolnir uses a two-branch, digest-promotion release model adapted from
[projectbluefin/dakota](https://github.com/projectbluefin/dakota).

## Branches

| Branch | Default? | Builds? | Image tag | Purpose |
| --- | --- | --- | --- | --- |
| `testing` | yes | yes | `:testing` | Integration trunk; all development and CI land here. |
| `stable` | no | **no** | `:stable` | Production pointer, moved only by digest promotion. |
| `main` | no | no | — | Historical pointer; retained for compatibility, not built. |

The build, plugin, multinode, quality and E2E workflows run on `testing`.
Pushes to `stable` do not trigger a rebuild — the branch exists so downstream
consumers and humans have a stable ref, and so the release workflow can record
the promoted commit.

## Cutting a stable release

Stable is cut **on demand**, never on a schedule. Both modes are dry-run by
default; promotion requires an explicit `--apply`.

```sh
just release                       # preflight: resolve + verify candidate, compare to :stable
just release --apply               # promote tested digest to :stable and cut a GitHub Release
just release --apply sha=<40-char> # recovery: promote a specific already-tested commit
```

What preflight does:

1. Resolves the candidate commit (testing HEAD unless `sha=` is given).
2. Confirms a successful `build` workflow run exists for that exact SHA.
3. Resolves the `:testing` image digest from that run's artifact.
4. Verifies the cosign keyless signature and SPDX attestation.
5. Compares the candidate digest with the current `:stable` digest and reports
   whether promotion is needed.

What `--apply` additionally does:

6. Re-tags the **exact verified digest** as `:stable` (no rebuild, no new layer).
7. Moves the `stable` Git branch to the candidate commit.
8. Creates a GitHub Release with a Conventional-Commits changelog and the SBOM.

If `:stable` already equals the candidate digest, promotion is a successful
no-op. A missing or unsigned candidate fails the release.

## Recovery

Pass `sha=<full-40-character-SHA>` to select an already-published testing commit
instead of HEAD. This bypasses only the "find the latest successful run" lookup —
digest resolution, signature verification and the apply-time checks still run.
Empty, abbreviated or malformed SHAs are rejected. Without an explicit SHA,
preflight and apply resolve HEAD independently and can select different commits
if `testing` advances between them; re-run preflight immediately before
`--apply` in that case.

## Rollback

Because promotion is digest-based and `stable` is never rebuilt, rolling back
means promoting an older known-good `:testing` digest with its full SHA (see
Recovery above). The image's bootc upgrade origin is unchanged; nodes running
`:stable` pick up the promoted digest on their next `bootc upgrade`.
