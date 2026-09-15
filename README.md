# tm-ai-skill

An AI skill for [TestManagement](https://github.com/JernejMrvar) that lets you manage test cases and test runs directly from your AI coding assistant — no browser needed.

## What it does

Point your AI tool at `SKILL.md` and it can:

- List, create, browse, and delete folders (including recursive subtree deletion with test-case preservation)
- List, create, edit, and delete project tags
- List, get, create, update, and delete test cases (with steps, priority, tags, and folder placement)
- List, get, create, and delete test runs
- Add and remove individual cases from a test run
- Report results in batch (pass/fail/blocked/skipped/flaky)
- Add comments and screenshots to individual case results
- Complete or cancel test runs

All actions are scoped to the project your API token belongs to and are recorded in the Audit Log.

## API-only safety boundary

This skill is deliberately API-only. Agents must use `$TM_BASE_URL/api/v1/*` with `TM_TOKEN` and must never fall back to the TestManagement browser UI, an authenticated browser session, or the session-based `/api/*` routes. If the token is missing, invalid, points at the wrong project, or the required v1 operation is unavailable, the agent stops and reports the problem instead of using browser credentials.

This distinction matters because a browser may already be signed in as an administrator with access to multiple projects. Browser/session operations are authorized as that user rather than scoped by the API token.

The installer downloads `SKILL.md` into `~/.codex/tm-api.md`,
`~/.claude/tm-api.md`, and `~/.cursor/rules/tm-api.md`; endpoint documentation
in `SKILL.md` is therefore the distribution source for all three installed
copies.

---

## Install

Run this once in your terminal on **macOS** or **Windows Git Bash**:

```bash
curl -fsSL https://raw.githubusercontent.com/JernejMrvar/tm-ai-skill/main/install.sh | bash
```

This will:
1. Install the skill for **Codex** → `~/.codex/tm-api.md` (registered in `~/.codex/AGENTS.md`)
2. Install the skill for **Claude Code** → `~/.claude/tm-api.md` (registered in `~/.claude/CLAUDE.md`)
3. Install the skill for **Cursor** → `~/.cursor/rules/tm-api.md`
4. Store your `TM_TOKEN` in the OS credential store
5. Write `~/.tm-config` with non-secret settings and credential lookup logic

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

**To get a token:** open your TestManagement project → **Project Settings → API Tokens → New Token**. Copy the `tm_...` value — it's shown only once.

To change the stored API token, rerun the installer. If a token is already stored, the installer asks you to paste a new one or press Enter to reuse the existing token.

To change `TM_BASE_URL`, rerun the installer so the token is stored under the matching credential target.

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
| macOS says `security` is missing | Run from a normal macOS terminal where `/usr/bin/security` is available. |
| Windows credential errors | Run from Git Bash on Windows with `powershell.exe` available and Credential Manager enabled. |
| `TM_TOKEN` is empty after `source ~/.tm-config` | The OS credential lookup failed or the credential is missing. Rerun the installer and paste a valid token when prompted. |
| `401 Unauthorized` | The stored token is invalid or belongs to another project. Generate a new token, rerun the installer, and paste the new token when it asks whether to replace the stored token. |
| Wrong base URL | Rerun the installer after changing `TM_BASE_URL`; credential targets are tied to the base URL. |
| Windows lookup feels slow | The generated config starts PowerShell to read Credential Manager. This startup cost is expected. |

---

## Skill reference

See [`SKILL.md`](SKILL.md) for the full API reference with curl examples.
