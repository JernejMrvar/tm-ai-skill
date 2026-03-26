# tm-ai-skill

An AI skill for [TestManagement](https://github.com/JernejMrvar) that lets you manage test cases and test runs directly from your AI coding assistant — no browser needed.

## What it does

Point your AI tool at `SKILL.md` and it can:

- List, create, and browse folders
- List tags
- List, get, create, update, and delete test cases (with steps, priority, tags, and folder placement)
- List, get, create, and delete test runs
- Add and remove individual cases from a test run
- Report results in batch (pass/fail/blocked/skipped/flaky)
- Add comments and screenshots to individual case results
- Complete or cancel test runs

All actions are scoped to the project your API token belongs to and are recorded in the Audit Log.

---

## Install

Run this once in your terminal:

```bash
curl -sSL https://raw.githubusercontent.com/JernejMrvar/tm-ai-skill/main/install.sh | bash
```

This will:
1. Install the skill for **Claude Code** → `~/.claude/tm-api.md` (registered in `~/.claude/CLAUDE.md`)
2. Install the skill for **Cursor** → `~/.cursor/rules/tm-api.md`
3. Create a `~/.tm-config` template for your credentials

---

## Configure

Open `~/.tm-config` and fill in your values:

```bash
TM_TOKEN=tm_your_token_here
TM_BASE_URL=https://test-management-project.vercel.app
```

**To get a token:** open your TestManagement project → **Project Settings → API Tokens → New Token**. Copy the `tm_...` value — it's shown only once.

---

## Use

Restart Cursor or Claude Code, then just ask:

> "List all test cases in the Login folder"

> "Create a test case called 'Reset password with invalid email' in the Auth folder, HIGH priority"

> "Create a test run called 'Regression — March sprint' for staging, then mark TC-42 as PASSED"

The AI will source your config automatically before making any API calls.

---

## Skill reference

See [`SKILL.md`](SKILL.md) for the full API reference with curl examples.
