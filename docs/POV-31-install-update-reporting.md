# POV-31 — Install/update/reporting client implementation

What this repository now implements for the POV-30 server contract
(`docs/POV-30-skill-releases-installations.md` in `TestManagementProject`),
in the same candid style as that document: what was built, what was
actually verified, and what remains open. The Settings command builder
that renders a copyable install command is a separate app-repo piece
(POV-32) and is **not** implemented here — this repo implements everything
needed to *consume and execute* such a command, plus direct interactive/
scripted use of `install.sh` on its own.

## What was implemented

### Modes (`install.sh <mode> [options]`)

- `install` (default) and `reconfigure` — the only modes that ever create,
  prompt for, or replace a credential. Both validate a candidate token
  against `GET /api/v1/me` (and, for a personal key, `GET /api/v1/projects`
  with no project header) *before* touching the OS credential store or
  `~/.tm-config`, so an invalid candidate never overwrites a working setup.
- `update` — syncs target files against the promoted release only; never
  touches the credential. No promoted release means no update, not a
  fallback to an unpinned download.
- `check` — reports current local state (installed files vs. last-recorded
  version/digest, credential validity) without changing anything.
- `retry-report` — resends a previously undelivered installation report,
  re-validating the credential's owner/deployment/generation against the
  pending report's retry identity first (see "Reporting" below).

The token is never accepted as a `--token` argument. `install`/
`reconfigure` read it from stdin when stdin isn't a TTY (the path a
rendered bootstrap command uses) or via a `/dev/tty` prompt interactively.
Exit codes: `0` all requested local work succeeded (a report may still be
pending, and the summary says so), `1` local/validation failure or partial
local failure, `2` usage/dependency/platform error; `retry-report` exits
nonzero whenever delivery is still pending after the attempt.

### Credential lifecycle

- Distinguishes legacy (`tm_`) vs. personal (`tmp_`) credentials by their
  validated `GET /api/v1/me` response (`kind: "legacy" | "personal"`),
  never by prefix alone.
- `credentialVerification.result: verified` is only ever produced by
  `do_credential_verification`, which spawns a **separate `bash` process**
  with `TM_TOKEN` explicitly unset, sources the persisted `~/.tm-config`
  fresh in that process, and re-validates via `/api/v1/me` — the
  just-supplied candidate token is never used to claim `verified`.
- A different identity already configured for a deployment requires
  `--switch-account` (or an interactive confirmation); this is tracked via
  a small non-secret `last_identity` marker under the deployment-scoped
  local state directory, not by attempting to enumerate OS-store entries.
- Legacy tokens can install/update normally but never attempt to report
  (the server's report endpoint is personal-key-only); this is stated
  explicitly in the console output rather than silently skipped.

### Release manifest consumption

`validate_release`/`release_target_available` implement the
`skillReleaseSchema` checks that matter client-side: `schemaVersion: 1`,
`release: null` as a valid inert state, `releaseVersion` a positive
integer, `channel: "stable"`, a stable (no-prerelease) SemVer
`installerVersion`, `contractVersions` compatibility against this
installer's own `SUPPORTED_REPORT_CONTRACT_VERSION` /
`SUPPORTED_MANIFEST_CONTRACT_VERSION` / `SUPPORTED_TM_API_CONTRACT_VERSION`
constants (exact match on the first two, `tmApiContractVersion` must not
exceed what's supported), and per-target artifact resolution requiring
*exactly one* `kind: "bundle"` artifact with a 64-hex lowercase `sha256`,
a positive `sizeBytes`, and an immutable `https://` URL (rejecting
`main`/`latest`/`master`/`head`/`trunk` path segments, case-insensitively).
One bad/ambiguous target's artifact never invalidates the other targets.

`install`/`reconfigure` use the unpinned legacy download only after a
successfully fetched and validated manifest explicitly reports
`release: null`. A network failure, malformed manifest, or incompatible
promoted release fails closed and leaves existing target files unchanged.

A SemVer comparison helper (`semver_compare`) implements semver.org
precedence including prerelease-identifier comparison (numeric vs.
alphanumeric, per-dot-segment) and ignores build metadata, matching the
fixtures exercised in `tests/install_helpers_test.sh` (added in this
change) and manually checked against the canonical
`1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < …` chain
from the SemVer spec.

### Download, archive safety, and staged replacement

`download_release_artifact` pins `curl --proto '=https'` (rejects any
http transport, including a downgraded redirect), bounds redirects/time/
size, and verifies both byte size and sha256 before anything is extracted.
`validate_archive_entries` inspects `tar -tvzf` output and rejects
absolute paths, `..` traversal, any non-file/non-directory entry type
(symlinks, hardlinks, specials), and any path outside the expected
`tm-ai-skill-<version>/<file>` layout — all before `tar -x` ever runs, and
extraction always lands in a private `mktemp -d` stage, never directly
under `$HOME`.

Each target (`codex`/`claude`/`cursor`) is staged to a temp file beside its
real destination and replaced with `mv -f` (same-filesystem atomic
rename); a pre-existing file is backed up and restored if the follow-up
registration edit (the `AGENTS.md`/`CLAUDE.md` include line) fails, so one
target's failure never corrupts another target's already-committed state.
`update` compares the file's actual on-disk sha256 against what was last
recorded for that exact version before ever deciding a target is safe to
overwrite — an existing file with no recorded state, or one whose digest
no longer matches what was recorded, is treated as an unknown local
edit and skipped rather than silently clobbered. `install`/`reconfigure`
always proceed (that's the point of running them explicitly).

### Local and reporting state

Two separate directories under `~/.tm/`:

- `~/.tm/_local/<sha256(deploymentUrl)>` — per-target installed
  version/digest, credential-independent, always available (so version
  tracking works even for legacy-token installs, which have no owner-
  scoped identity).
- `~/.tm/<sha256(deploymentUrl|ownerId)>` — the owner-scoped installation
  identity (`installationId`, `sequence`, `pendingReport`,
  `retryIdentity`), personal-key only.

Both are `jq`-managed JSON, `chmod 700`/`600`, coordinated by a portable
`mkdir`-based lock (works without `flock`, which isn't guaranteed on
macOS or Git Bash). A sequence is allocated and persisted *before* the
network call, so a failed delivery attempt doesn't silently consume a new
sequence on the next retry — `retry-report` resends the persisted
`pendingReport` unchanged unless the credential's generation has since
rotated, in which case it discards the stale claim and submits a fresh
observation instead (see the retry-identity rules in the POV-30 doc,
section 4).

### Reporting client

`build_report_body` produces the exact `skillInstallationReportSchema`
shape (`schemaVersion: 1`, lowercase `installationId`, integer `sequence`,
`operation`, optional `displayName`, `installerVersion`,
`credentialVerification`, `targets[]` with `result`/`observedVersion`/
`attemptedVersion`/`failureCode` only where meaningful) — verified by hand
against the actual Zod schema in `TestManagementProject`'s
`lib/validations/skill-installation.ts` (both repos were available in this
environment). `submit_operation_report` refuses to send an empty
`targets: []` with `credentialVerification.result: not_checked` (the
server rejects that combination with `400`). `handle_report_outcome` maps
`200`/`201` (with response-shape validation before treating it as
delivered), `401`, `403`, `404`, `409`, `413`, and any other/network
failure to the behavior described in the POV-30 doc's idempotency section.

### Bootstrap template

`bootstrap.sh` is the fixed, placeholder-based template a future Settings
command builder renders (substituting the deployment URL, artifact URL/
sha256/size, and mode) into the copyable install command. It performs its
own https-only/immutable-URL/sha256-format/size/mode validation before any
network call, downloads to a private temp directory, verifies digest and
size, runs the same archive-safety check as `install.sh`, and `exec`s the
extracted `install.sh` — the one-time key is never interpolated into it,
only piped to stdin by whatever invokes the rendered script. It is
deliberately not part of the packaged release bundle (`ALLOWED_FILES` in
`scripts/package-release.sh`), since it has to run *before* `install.sh`
exists on disk.

### Distributed guidance

`SKILL.md` (the single source copied to all three targets) gained a
"Personal API keys and deliberate project selection" section: explicit
`X-TM-Project-Id` on every project-scoped request even with one project,
establishing intent from explicit direction or an already-unambiguous
selection, revalidating a saved preference rather than trusting it,
asking once and sending zero mutations when ambiguous, never inferring a
project from list order/name/permissions/another task's choice/new
membership, binding and naming the selected project per operation, and
never retrying a blocked operation against another project/account/the
browser. `README.md`/`RELEASING.md` were updated to describe the new
modes, the `jq` dependency, and what the installer now actually consumes.

## Verification performed

- `bash -n install.sh` and `bash -n bootstrap.sh` — clean (the latter with
  its literal, unsubstituted `__PLACEHOLDER__` tokens, which is how it's
  always shipped from this repo; a renderer must substitute them before
  running it).
- Full test suite, run both individually and via the same `for test in
  tests/*_test.sh; do bash "$test"; done` loop CI uses:
  - `tests/install_helpers_test.sh` — 57/57 (the original 25 assertions,
    unmodified, still pass against the extended script; 32 new ones cover
    `semver_compare` against the SemVer spec's canonical prerelease-
    precedence chain, `is_stable_semver`, `validate_deployment_url`/
    `canonicalize_deployment_url`, deployment-scoped credential lookup,
    stdin prompt fallback, `is_immutable_https_url`,
    `generate_uuid`'s format, and newline-delimited exit-code aggregation).
  - `tests/skill_guardrails_test.sh` — 21/21 (11 pre-existing + 10 new,
    covering the new SKILL.md section's content and ordering).
  - `tests/package_release_test.sh` — 12/12 (unmodified; this PR didn't
    touch packaging, since no new files needed to enter the distributed
    bundle — `bootstrap.sh` deliberately isn't part of it).
  - `tests/release_and_report_test.sh` (new) — 44/44: release-manifest
    validation against realistic POV-30 fixtures (`release: null`, a valid
    envelope, an incompatible `tmApiContractVersion`); fail-closed handling
    for unavailable, malformed, and incomplete manifests; a full install →
    update (no-op) → locally-edited-skip → reconfigure-overwrite cycle
    against a *real* HTTP download/digest/extract/stage/commit round trip
    via a local fixture server (`tests/fixtures/fake_tm_server.py`); digest-
    mismatch and archive-safety (path-traversal, symlink) rejection with no
    file ever written, using archives built byte-for-byte with Python's
    `tarfile` module (`tests/fixtures/make_archive.py`) so the malicious
    entries are portable across whatever `tar` binary runs the test;
    report idempotent-replay and same-sequence-conflict behavior against
    real HTTP responses; a simulated cross-owner `404`.
  - `tests/bootstrap_test.sh` (new) — 10/10: the fail-fast validation gates
    (non-https URL, mutable `/main/` segment, malformed sha256, zero size,
    wrong mode) with no network involved, plus the full download/digest/
    archive-safety/extract/exec pipeline against a deterministic local
    `curl` stand-in.
- `build_report_body`'s output shape was hand-compared during development
  against `TestManagementProject`'s actual `skillInstallationReportSchema`
  (both repos were available in this environment); that specific
  cross-repo comparison isn't itself an automated/committed test, only the
  shape produced by the committed test fixtures above.
- Confirmed the *shipped* `download_release_artifact` (not the test's
  local override) rejects a plain `http://` URL outright, since the
  fixture server needed to relax that specific function and
  `is_immutable_https_url` for its own tests (documented inline in
  `tests/release_and_report_test.sh`).

## Not verified / deliberately deferred

This is security-sensitive, multi-platform code; being explicit about what
wasn't proven matters more than looking finished.

- **No native macOS Keychain run.** All credential-store tests (pre-existing
  and new) use a faked `security` shim on `$PATH`, as the original test
  suite already did — never a real Keychain. The read-back verification
  flow (`readback_me`/`do_credential_verification`) was only exercised
  against the fake fixture server with a fake token, never a real macOS
  Keychain entry plus a real `/api/v1/me`.
- **No native Windows Git Bash run at all.** The Windows Credential Manager
  PowerShell path is unchanged from the pre-existing installer and wasn't
  touched by this change, but the *new* archive extraction (`tar -xzf`),
  `tar -tvzf` entry-type parsing in `validate_archive_entries`, and
  `sha256sum` selection were never run on real Windows Git Bash — only
  macOS `bsdtar`/`shasum` in this environment. GNU tar (likely what ships
  with Git for Windows) and BSD tar format their `-tv` listings slightly
  differently; the entry-type-character and last-whitespace-field parsing
  in `validate_archive_entries`/`bootstrap.sh` was written to be robust to
  both but only actually tested against one.
- **No real HTTPS artifact download.** `download_release_artifact` and
  `bootstrap.sh` both pin `--proto '=https'` and were unit-tested for that
  rejection, but the "happy path" download/digest/extract pipeline was
  only exercised against a local plain-HTTP fixture server (with the
  https-only checks locally overridden/bypassed in the test, as documented
  there) or a deterministic `curl` stand-in — never a real TLS connection,
  a real redirect chain, or a real GitHub Releases asset URL.
- **No real two-device / concurrent-report race.** The idempotent-replay,
  same-sequence-conflict, and cross-owner-404 paths were exercised against
  a single-process fixture server handling requests sequentially from one
  test script. Real concurrent reports from two devices racing the same
  installation, or a rotation racing a report (the scenario
  `TestManagementProject`'s own POV-30 doc explicitly flags as unproven
  against real Postgres), were not reproduced here.
- **`409 STALE_REPORT` recovery is a documented limitation, not a full
  reconciliation.** The server's error responses carry no information
  about its actual current highest sequence, so on `409` this client
  discards the stale pending report and lets the *next* explicit operation
  (not an automatic retry) allocate a fresh sequence from local state. If
  local state has fallen far behind the server's (e.g. after restoring an
  old backup of `~/.tm`), a single retry might not be enough to catch up;
  this was not exercised end-to-end.
- **`DISK_FULL` vs. `WRITE_PERMISSION_DENIED` classification is a stderr
  string heuristic** (`commit_target` greps the failing `mv`'s captured
  stderr for `"No space left"`/`"Permission denied"`), not verified
  against a real full disk or a real permission-denied filesystem — only
  a writable-directory pre-check (`[ -w ... ]`) was actually exercised.
- **No shell linter.** This repo has no `shellcheck` (or similar)
  configured, and none was added; only `bash -n` syntax checks and the
  functional test suites above were run.
- **No structured scenario fixtures / recorded prompt-to-request checks
  for the intent/guardrail matrix in the original plan's verification
  table** (two identically-named writable projects, stale other-owner
  preference, new membership, cross-project nested ID, etc.). What exists
  is static text-and-ordering assertions in `tests/skill_guardrails_test.sh`
  confirming the guidance is present and correctly placed — not a live or
  recorded agent evaluation against fixture endpoints proving an LLM
  actually follows it. The plan explicitly flags "text assertions alone do
  not establish agent behavior"; that gap is real and unresolved here.
- **The Settings command builder itself (POV-32) is out of scope** for this
  repository by design — `bootstrap.sh` is the template such a builder
  would render, but nothing here proves a real rendered/substituted
  command round-trips correctly through that not-yet-built server-side
  piece.
- **No live TestManagement deployment was used anywhere in this work** —
  every credential, project, and report interaction above is against the
  local fixture server or fake shims, per the environment's constraints.

## Testing dependencies

`tests/release_and_report_test.sh` and `tests/bootstrap_test.sh` (for its
path-traversal fixture) require `python3` on the machine running the test
suite — not a runtime dependency of `install.sh`/`bootstrap.sh`
themselves, only of the test fixtures. Both test files check for it and
exit with a clear message rather than silently skipping if it's absent.
