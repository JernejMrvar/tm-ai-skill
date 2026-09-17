# tm-ai-skill

An AI skill for [TestManagement](https://github.com/JernejMrvar) that lets you manage test cases and test runs directly from your AI coding assistant — no browser needed.

## What it does

Point your AI tool at `SKILL.md` and it can:

- List, create, browse, and delete folders (including recursive subtree deletion with test-case preservation)
- List, create, edit, and delete project tags
- List, get, create, update, and delete test cases (with steps, priority, tags, and folder placement)
- List, get, create, and delete test runs
- Use additive project-scoped public references such as `WEB-1` while retaining legacy numeric IDs
- Add and remove individual cases from a test run
- Report results in batch (pass/fail/blocked/skipped/flaky)
- Add comments and screenshots to individual case results
- Complete or cancel test runs

All actions are scoped to the project your API token belongs to and are recorded in the Audit Log.

## API-only safety boundary

This skill is deliberately API-only. Agents must use `$TM_BASE_URL/api/v1/*` with `TM_TOKEN` and must never fall back to the TestManagement browser UI, an authenticated browser session, or the session-based `/api/*` routes. If the token is missing, invalid, points at the wrong project, or the required v1 operation is unavailable, the agent stops and reports the problem instead of using browser credentials.

This distinction matters because a browser may already be signed in as an administrator with access to multiple projects. Browser/session operations are authorized as that user rather than scoped by the API token.

Public test-case references use the distinct `PROJECTCODE-N` form (for
example `WEB-1`). Use `/api/v1/projects/by-code/{code}/...` for explicit
lookups, `testCasePublicIds` when adding cases to a run, and
`testCasePublicId` when reporting results. Keep legacy numeric IDs for
compatibility and never supply `publicNumber` on create requests.

The installer downloads `SKILL.md` into `~/.codex/tm-api.md`,
`~/.claude/tm-api.md`, and `~/.cursor/rules/tm-api.md`; endpoint documentation
in `SKILL.md` is therefore the distribution source for all three installed
copies.

---

## Install

Run this once in your terminal on **macOS** or **Windows Git Bash** (also requires `jq`, in addition to `curl`/`tar`/`shasum`-or-`sha256sum` which normally already ship with the OS):

```bash
curl -fsSL https://raw.githubusercontent.com/JernejMrvar/tm-ai-skill/main/install.sh | bash
```

This will:
1. Install the skill for **Codex** → `~/.codex/tm-api.md` (registered in `~/.codex/AGENTS.md`)
2. Install the skill for **Claude Code** → `~/.claude/tm-api.md` (registered in `~/.claude/CLAUDE.md`)
3. Install the skill for **Cursor** → `~/.cursor/rules/tm-api.md`
4. Store your API token in the OS credential store
5. Write `~/.tm-config` with non-secret settings and credential lookup logic
6. If the deployment has promoted a versioned release, install pinned/checksum-verified content and record its version; if a successfully validated manifest explicitly says no release is promoted, fall back to the current unpinned `SKILL.md` (today's production state — no release is promoted yet). Manifest failures leave existing files unchanged.

### Modes

```bash
install.sh              # default: install (may create/prompt for a credential)
install.sh reconfigure  # explicitly replace the stored credential, then sync files
install.sh update       # sync files against the promoted release; never touches the credential
install.sh check        # report current local state; never touches files or the credential
install.sh retry-report # resend a previously undelivered installation report
```

`update`, `check`, and `retry-report` never create, rotate, revoke, or prompt for a credential — only `install`/`reconfigure` do. The token is never accepted as a `--token` argument (it would be visible in process listings); pipe it on stdin for non-interactive use (e.g. a generated install command) or run interactively for a secure `/dev/tty` prompt.

Other options: `--base-url=URL`, `--display-name=NAME`, `--target=codex,claude,cursor` (default: all three), `--switch-account` (required to replace a stored credential for a different account on the same deployment), `--yes`.

Exit codes: `0` all requested local work succeeded (a report may still be pending — the summary says so explicitly), `1` a local/validation failure or partial local failure, `2` a usage/dependency/platform error. `retry-report` exits nonzero whenever delivery is still pending after the attempt.

---

## Configure

The installer prompts for your API token securely, then stores it in:

- macOS Keychain, using service `TestManagement API Token`
- Windows Credential Manager, using target `TestManagement API Token:<base-url>`

Agents still load credentials the usual way:

```bash
source ~/.tm-config 2>/dev/null
```

Do not paste `TM_TOKEN` into `~/.tm-config`. That file should contain only `TM_BASE_URL`, credential metadata, and a command that looks up the token from the OS credential store. If you already had a plaintext `TM_TOKEN=tm_...` in `~/.tm-config`, the installer migrates it into the credential store, writes a redacted backup, and rewrites the config without the secret.

**To get a token:** open your TestManagement project → **Project Settings → API Tokens → New Token** for a legacy, project-scoped `tm_...` token, or your account's personal-key settings for a `tmp_...` key that can span multiple projects (see [`SKILL.md`](SKILL.md) for the project-selection rules that apply to personal keys). Either is shown only once.

To change the stored API token, run `install.sh reconfigure` (or the default `install.sh`, which offers the same replace-or-reuse prompt). A different account for an already-configured deployment requires `--switch-account` — this is a deliberate choice, not something the installer does automatically.

To change `TM_BASE_URL`, pass `--base-url=` (or edit `~/.tm-config` and rerun `reconfigure`) so the token is stored under the matching credential target.

---

## Use

Restart Codex, Cursor, or Claude Code, then just ask:

> "List all test cases in the Login folder"

> "Create a test case called 'Reset password with invalid email' in the Auth folder, HIGH priority"

> "Create a test run called 'Regression — March sprint' for staging, then mark TC-42 as PASSED"

The AI will source your config automatically before making any API calls.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Installer says Linux or WSL is unsupported | Run the installer on macOS or Windows Git Bash. The installer exits before changing files on unsupported platforms. |
| Installer exits with a missing-dependency error | Install `jq` (plus `curl`/`tar`/`shasum`-or-`sha256sum`, which normally already ship with the OS) and rerun. |
| macOS says `security` is missing | Run from a normal macOS terminal where `/usr/bin/security` is available. |
| Windows credential errors | Run from Git Bash on Windows with `powershell.exe` available and Credential Manager enabled. |
| `TM_TOKEN` is empty after `source ~/.tm-config` | The OS credential lookup failed or the credential is missing. Rerun `install.sh reconfigure` and paste a valid token when prompted. |
| `401 Unauthorized` | The stored token is invalid, expired, or belongs to another project/owner. Generate a new token and run `install.sh reconfigure`. |
| A different account is already configured for this deployment | Pass `--switch-account` to `install.sh reconfigure` to replace it deliberately, or confirm the interactive prompt. |
| Wrong base URL | Run `install.sh reconfigure --base-url=<url>`; credential targets are tied to the base URL. |
| Windows lookup feels slow | The generated config starts PowerShell to read Credential Manager. This startup cost is expected. |
| `install.sh update` says no target was updated | Either no compatible release is currently promoted (see below), or the local file's content doesn't match what the installer last recorded (e.g. you edited it) — run `install.sh reconfigure` to force a specific target, or pass `--target=`. |
| `install.sh retry-report` exits nonzero | The report is still undelivered (network issue, or the server rejected it — see its console output for the reason) or the stored credential no longer matches the identity the report was queued under. |

---

## Server contract for versioned releases and installation reporting

`TestManagementProject` (POV-30) defines a server-side contract this
installer now consumes when a compatible release is promoted:

- `GET /api/v1/skill-release` — a public, credential-free endpoint serving
  the deployment's promoted release manifest (version, per-target payload
  versions, and immutable artifact URLs/checksums), or an explicit "no
  release promoted" state. `install`/`reconfigure` fall back to the
  existing unpinned `SKILL.md` download only when no compatible release is
  promoted yet (today's actual production state); `update`/`check` never
  fall back to an unpinned download — no release simply means nothing to
  update.
- `POST /api/v1/skill-installations/report` — a personal-API-key-only
  endpoint for self-reporting install/update/check observations per
  installation, so a TestManagement account's Settings page can show which
  of its own devices are up to date. Legacy `tm_` tokens can install and
  update normally but cannot report (`403 PERSONAL_KEY_REQUIRED`).

See `TestManagementProject`'s `docs/POV-30-skill-releases-installations.md`
for the full server-side contract, and
[`docs/POV-31-install-update-reporting.md`](docs/POV-31-install-update-reporting.md)
in this repo for exactly what the installer implements, what was verified
by the test suite, and what remains open (native OS acceptance runs, real
multi-device timing races, and the Settings command builder itself, which
ships separately). This repo's own release process — packaging and
publishing the bundle — is documented in [`RELEASING.md`](RELEASING.md).
`bootstrap.sh` documents the small fixed template a future Settings-
generated install command renders around a pinned release artifact.

## Skill reference

See [`SKILL.md`](SKILL.md) for the full API reference with curl examples.
