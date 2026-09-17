# Releasing tm-ai-skill

This covers **publishing** a versioned installer/skill release from this
repository — packaging, checksums, and a GitHub Release. It does not cover
**promoting** a published release into a live TestManagement deployment,
which is a separate, reviewed step in the `TestManagementProject` repo (see
"Promote" below). Installer command handling, staged downloads, client-side
digest verification, and reporting installation observations to
TestManagement are POV-31's scope and are not implemented in this repo yet —
today's `install.sh` still downloads `SKILL.md` from `main` with no
release/reporting flow. This document only covers packaging what already
exists.

## Versioning

`VERSION` at the repo root is the single source of truth for this repo's
current SemVer version. It describes the packaged `install.sh` + `SKILL.md`
bundle as a whole — there is one payload installed identically to Codex,
Claude Code, and Cursor today, so there is no per-target version split yet.

Bump `VERSION` in a normal, reviewed commit before tagging. The packaging
script (`scripts/package-release.sh`) always reads `VERSION` from the
**tagged commit**, never the working tree, so an untagged or unrelated
in-progress edit can never be packaged by accident.

## Publish (this repo)

1. Bump `VERSION` and merge that commit.
2. Tag the merged commit — the tag name and the `VERSION` file content must
   match:
   ```bash
   git tag vX.Y.Z <commit>
   git push origin vX.Y.Z
   ```
3. `.github/workflows/release.yml` triggers on the tag push. It verifies the
   tag matches `VERSION`, runs the test suite, packages the tag with
   `scripts/package-release.sh`, and publishes a numbered GitHub Release
   (`releases/tag/vX.Y.Z`) with the tarball and its manifest attached as
   immutable assets. **Never** reference a `main`/`latest` URL as a release
   artifact — always the numbered tag's asset URL, e.g.:
   ```text
   https://github.com/<owner>/tm-ai-skill/releases/download/vX.Y.Z/tm-ai-skill-X.Y.Z.tar.gz
   ```
4. To inspect a package locally before tagging (or to publish out of band):
   ```bash
   ./scripts/package-release.sh vX.Y.Z
   ```
   This packages only the committed content at that ref and fails closed if
   the ref tracks a file outside the packaging allowlist (see
   `ALLOWED_FILES` in `scripts/package-release.sh`) — so a stray committed
   config or credential file can never ship silently.

## Promote (TestManagementProject repo)

Publishing here changes nothing for any deployment by itself. A
TestManagement deployment only serves a release once someone commits its
exact, already-verified metadata to `config/ai-skill-release.json` in
`TestManagementProject` — see that repo's
`docs/POV-30-skill-releases-installations.md` for the full manifest contract.

1. Download the published tarball from its GitHub Release asset URL and
   verify its sha256 against the published `.manifest.json` — never trust an
   unfetched value when writing the manifest commit.
2. In `TestManagementProject`, set the `release` object in
   `config/ai-skill-release.json`:
   - `releaseVersion` — a monotonic integer local to that manifest,
     independent of this repo's SemVer `VERSION`.
   - `installerVersion` and every `targetVersions.{codex,claude,cursor}` —
     all set to this repo's `VERSION` (one payload serves all three targets
     today).
   - `contractVersions` — see the note below before setting these.
   - `artifacts` — one entry per target (`codex`, `claude`, `cursor`), all
     three pointing at the same tarball's URL/sha256/sizeBytes, since there
     is only one payload.
3. **Do not** set `contractVersions.reportContractVersion` /
   `manifestContractVersion` to values implying personal-key/installation-
   reporting support until POV-31 actually ships that client behavior in
   this repo. A baseline release of the current legacy installer must only
   claim its actual legacy capabilities — never the new contract ahead of
   the code that implements it.
4. Get that manifest commit reviewed and deployed like any other change.
   There is no separate "activation" step: `GET /api/v1/skill-release` reads
   the bundled file directly, and Settings recomputes version-comparison
   states on every read.

## Rollback

Revert the `config/ai-skill-release.json` commit in `TestManagementProject`
(or restore `"release": null`) in a new, reviewed commit. This never
unpublishes the GitHub Release here, never forces an already-updated local
installation to downgrade, and never rotates or revokes any TestManagement
credential.
