# tm-ai-skill

An AI skill for [TestManagement](https://github.com/JernejMrvar) that lets you manage test cases and test runs directly from your AI coding assistant — no browser needed.

## What it does

Point your AI tool at `SKILL.md` and it can:

- List and browse folders and test cases
- Create test cases with steps, priority, tags, and folder placement
- Create test runs and report results (pass/fail/blocked/etc.)
- Add comments and screenshots to individual case results
- Complete or cancel test runs

All actions are scoped to the project your API token belongs to and are recorded in the Audit Log.

## Usage

### 1. Get an API token

In your TestManagement project: **Project Settings → API Tokens → New Token**

Copy the `tm_...` token — it's shown only once.

### 2. Set environment variables

```bash
export TM_TOKEN="tm_your_token_here"
export TM_BASE_URL="https://your-app.vercel.app"
```

### 3. Register the skill with your AI tool

**Cursor / Claude Code** — add to your `CLAUDE.md`:

```markdown
| TestManagement API | [SKILL.md](path/to/tm-ai-skill/SKILL.md) | Bearer token, test cases, test runs |
```

Then ask naturally:

> "List all test cases in the Login folder"

> "Create a test case called 'Reset password with invalid email' in the Auth folder, HIGH priority"

> "Create a test run called 'Regression — March sprint' for staging, then mark TC-42 as PASSED"

## Skill reference

See [`SKILL.md`](SKILL.md) for the full API reference with curl examples.
