# TestManagement AI Skill

Use this skill to manage test cases and test runs in a TestManagement project directly through its token-authenticated API.

## Mandatory API-only guardrail

All TestManagement reads and writes performed under this skill must use direct HTTP requests to `$TM_BASE_URL/api/v1/*` with the configured `TM_TOKEN` bearer token.

- **Never open or control a browser to perform a TestManagement operation.** Do not navigate the TestManagement UI, click its forms, execute requests in a page context, or use an existing signed-in browser session.
- **Never call the browser/session API routes under `/api/*`.** In particular, `/api/test-cases` is not an alternative to `/api/v1/test-cases`; it uses the logged-in browser user's permissions and is not scoped by `TM_TOKEN`.
- Browser availability, an existing login, or broader permissions on the logged-in user do not authorize switching away from the token-authenticated API.
- If credentials are missing, authentication fails, the requested project cannot be identified through the token-scoped v1 responses, or a required v1 operation is unavailable, stop and report the problem. **Do not fall back to the browser, the UI, session cookies, or a non-v1 endpoint.**
- The project selected by `TM_TOKEN` is the only project in scope. Do not search for or switch to another project through the browser. If the returned folders, tags, test cases, or test runs do not match the user's intended project, make no mutations and ask the user to configure the correct project token.

This restriction applies even when browser-control tools are available. A successful write made through this skill should be attributed in the TestManagement Audit Log as `API: <token name>`, never as the logged-in browser user.

## Public identifiers and legacy IDs

The token remains scoped to one project. Responses now include additive
`projectCode`, `publicNumber`, and `publicId` fields where available. A test
case public ID is formatted as `{projectCode}-{publicNumber}`, for example
`WEB-1`. Folder and run numbers are separate sequences in the same project;
use their explicit resource route or response field to know which namespace a
number belongs to.

Keep existing numeric `id`, `testCaseId`, and `testRunCaseId` values for
legacy clients and nested mutations. Never reinterpret a legacy numeric ID as
a public number, and never send a caller-supplied `publicNumber` when creating
a resource—the API allocates it. When a public and legacy reference are both
provided, they must identify the same test case. In a batch results request, a
mismatch rejects only that result: the API continues processing the other
results and returns HTTP 200 with details in the response `errors` array.

For lookup by public reference, use the project-code routes:

```text
GET /api/v1/projects/by-code/{code}
GET /api/v1/projects/by-code/{code}/test-cases/{publicNumber}
GET /api/v1/projects/by-code/{code}/folders/{publicNumber}
GET /api/v1/projects/by-code/{code}/test-runs/{publicNumber}
```

For run mutations, `POST /api/v1/test-runs/{runId}/cases` accepts
`testCasePublicIds` (for example `{"testCasePublicIds":["WEB-1"]}`) and
`POST /api/v1/test-runs/{runId}/results` accepts `testCasePublicId` while
retaining `testCaseId` for compatibility. Resolve or validate references
against the token-scoped project before mutating.

## Personal API keys and deliberate project selection

A `tmp_...` personal key is not scoped to a single project the way a
legacy `tm_...` token is. Discover identity and access with
`GET /api/v1/me` and `GET /api/v1/projects` (no project header on either —
both are credential-only routes), then send an explicit
`X-TM-Project-Id: <id>` header on every subsequent project-scoped request,
even when discovery returns exactly one project. An empty project list or
Guest/read-only access is a valid discovery result, not an error. Legacy
`tm_...` tokens keep their existing single implied project and never need
this header.

- Establish the intended project from explicit user direction in this task,
  or from an unambiguous selection already established earlier in the same
  task. A previously saved project preference is only a hint scoped to this
  deployment and owner — revalidate it against current discovery before
  reusing it, never treat it alone as authorization for ambiguous work.
- If more than one project is available and the user's intent is unclear,
  ask once which project before making any request that would mutate data.
  Send zero mutations until the project is resolved.
- Never choose a project by list order, a repository/folder name match, the
  key's write permission on one candidate, similarity to another resource's
  name, another task's earlier selection, or a project becoming newly
  available through changed membership. None of these are user intent.
  Existing and newly available projects otherwise follow the key's actual
  permissions; do not invent or reinstate an allowlist beyond that.
- Bind every operation and lookup to the selected project and name that
  project in any summary of what was done. Preserve the selection across an
  authorized continuation of the same task in the same project without
  re-asking; an explicit switch, or genuinely independent multi-project
  work, establishes the project for each new target separately.
- Resolve public, numeric, and nested IDs within the selected project only.
  Missing access, a read-only/excluded scope, a stale saved selection, a
  resource that actually belongs to a different project, a contradictory
  reference, or failed authentication stops the affected operation — do not
  retry it against a different project, account, or the browser to force a
  success.

## Before making any API call

Run the following to load credentials, then check `TM_TOKEN` is set:

```bash
source ~/.tm-config 2>/dev/null
```

If `TM_TOKEN` is empty after sourcing, report that credential lookup failed. Tell the user to rerun the installer and check troubleshooting for missing OS credentials, missing `security` on macOS, Windows PowerShell/Credential Manager errors, invalid tokens, unsupported Linux/WSL, or base URL changes.

---

## Setup

### 1. Generate an API token

1. Open your project in the app
2. Go to **Project Settings → API Tokens** for a legacy, project-scoped token, or your account's personal-key settings for a `tmp_...` key that can span multiple projects
3. Click **New Token**, give it a name (e.g. `ai-local`), select a "Run as" member (legacy tokens only)
4. Copy the token — a legacy token starts with `tm_`, a personal key with `tmp_`, and either is shown **only once**

### 2. Run the installer

```bash
curl -fsSL https://raw.githubusercontent.com/JernejMrvar/tm-ai-skill/main/install.sh | bash
```

The installer supports macOS and Windows Git Bash and requires `jq` in addition to `curl`/`tar`/`shasum`-or-`sha256sum`. It prompts for the token through `/dev/tty` (or reads it from stdin when run non-interactively, e.g. from a generated install command — never as a `--token` argument), stores it in the OS credential store, and writes `~/.tm-config` with non-secret exports and lookup logic. If a token is already stored, the installer asks for a replacement token and treats blank input as "reuse the existing token". Do not manually write plaintext `TM_TOKEN` values into `~/.tm-config`.

Beyond the default interactive install, the installer supports explicit
modes: `install.sh reconfigure` to deliberately replace the stored
credential, `install.sh update` to sync skill files against a promoted
release without ever touching the credential, `install.sh check` to report
current local state, and `install.sh retry-report` to resend a previously
undelivered installation report. Only `install`/`reconfigure` ever create,
prompt for, or rotate a credential.

`~/.tm-config` should define:

```bash
export TM_BASE_URL="https://test-management-project.vercel.app"   # or http://localhost:3000 for local dev
export TM_TOKEN="$(...credential lookup...)"
```

Every request must include:

```http
Authorization: Bearer tm_xxxxxxxx
```

The token implicitly scopes all operations to its project — there is no `projectId` query param on v1 routes.

---

## Test case design defaults

These are defaults, not rules; user instructions override them.

- Prefer user-facing product-area folders, not implementation details, routes, callbacks, or token mechanics.
- Prefer shallow folder structures and reuse existing folders.
- Create subfolders only when there are 3+ meaningful cases or the user asks.
- For auth, default to `Authentication > Login` and `Authentication > Register`.
- Do not create `Auth Callback`, `Session & Access Control`, `Magic Link`, `Password Recovery`, or `Account Confirmation` folders by default; place those cases under `Login` or `Register` unless the user asks for more granularity.
- Create compact starter suites by default: small flow 3-5 cases, medium flow 6-10 cases, and ask before creating more than 10.
- Avoid separate cases for every token, callback, or expired-link edge case unless the user asks for detailed negative coverage.
- Populate step `data` whenever a step depends on concrete inputs: test accounts, fixtures, uploaded files, generated files, API endpoints, request payloads, expected visible values, error messages, or environment/setup values. Do not hide this information only in the description or preconditions; put it on the step where it is used.
- Tags should be sparse:
  - `smoke` = the smallest must-pass set proving the core app is accessible and usable; do not tag every happy path as smoke
  - `api` = only direct endpoint/request-response tests
  - `e2e` = only if the user asks for execution-type tagging
  - `regression` = do not apply by default
  - Do not tag with a folder name like `login` inside the `Login` folder
  - Do not use `ui` unless specifically visual/layout/component behavior
- Before creating more than 5 cases, summarize proposed folders, case count, and tags, then ask for confirmation unless the user already gave strong instructions.
- Folder deletion is recursive and destructive: list folders first, confirm the exact folder ID, and explain that deleting it also deletes descendants while preserving their test cases with `folderId` set to `null`.

### Auth starter suite example

`Authentication > Login`:

- Login succeeds with valid user credentials [`smoke`]
- Login with invalid credentials shows an error
- Admin login succeeds with valid admin credentials [`smoke`]
- Forgot password request succeeds
- Reset password succeeds
- Magic link login succeeds
- Protected routes require authentication [`smoke`]
- Logout clears the active session [`smoke`]

`Authentication > Register`:

- Registration succeeds with valid account details [`smoke`]
- Account confirmation succeeds

---

## Enums

| Domain | Values |
|--------|--------|
| Test case `status` | `DRAFT`, `ACTUAL`, `DEPRECATED` |
| Test case `priority` | `LOW`, `MEDIUM`, `HIGH`, `CRITICAL` |
| Test run `status` | `PLANNED`, `IN_PROGRESS`, `COMPLETED`, `CANCELLED` |
| Result / run-case `status` | `PASSED`, `FAILED`, `BLOCKED`, `SKIPPED`, `FLAKY` |

---

## List folders

`GET /api/v1/folders`

Returns folders with `publicNumber`, `publicId`, `projectCode`, and `testCaseCount` per folder.

When presenting a folder list to the user, do not include folder identifiers
(`id`, `publicNumber`, or `publicId`) unless the user explicitly asks for them
or an identifier is required for a requested mutation such as deletion.

```bash
curl -sS -H "Authorization: Bearer $TM_TOKEN" "$TM_BASE_URL/api/v1/folders"
```

Response shape: `{ "folders": [ { "id", "name", "parentId", "position", "testCaseCount", ... } ] }`

---

## Create folder

`POST /api/v1/folders` — JSON body.

| Field | Notes |
|-------|-------|
| `name` | required |
| `parentId` | optional int; must belong to the project |

```bash
curl -sS -X POST -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Auth","parentId":null}' \
  "$TM_BASE_URL/api/v1/folders"
```

## Delete folder

`DELETE /api/v1/folders/{id}`

The folder ID must belong to the project selected by `TM_TOKEN`. A successful
deletion returns `{ "success": true }` with HTTP `200`. Missing, cross-project,
or already-deleted folders return `404`.

Deletion removes the selected folder and its entire descendant subtree. Test
cases in the selected folder or any descendant are preserved and become
unfiled (`folderId: null`); empty folders are removed as well.

```bash
curl -sS -X DELETE \
  -H "Authorization: Bearer $TM_TOKEN" \
  "$TM_BASE_URL/api/v1/folders/42"
```

---

## List tags

`GET /api/v1/tags`

Returns all tags in the project ordered by name.

```bash
curl -sS -H "Authorization: Bearer $TM_TOKEN" "$TM_BASE_URL/api/v1/tags"
```

Response shape: `{ "tags": [ { "id", "name" } ] }`

## Create tag

`POST /api/v1/tags` — JSON body.

| Field | Notes |
|-------|-------|
| `name` | required; surrounding whitespace is trimmed, then the value must be 1–100 characters |
| `color` | optional six-digit hex color such as `#3B82F6`; defaults to `#6B7280` |

The response is the created tag `{ "id", "name", "color" }` with HTTP `201`.
Tag names must be unique within the token's project; duplicates return `409`.

```bash
curl -sS -X POST \
  -H "Authorization: Bearer $TM_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"smoke","color":"#10B981"}' \
  "$TM_BASE_URL/api/v1/tags"
```

## Update tag

`PATCH /api/v1/tags/{id}` — JSON body with one or both fields:

```json
{ "name": "critical", "color": "#EF4444" }
```

The update is partial: omitted fields are preserved. Names are trimmed and
must be 1–100 characters; colors must be six-digit hex values. An empty
payload, malformed payload, or invalid field returns `400`. The response is
the updated tag `{ "id", "name", "color" }`. Duplicate names return `409`,
and missing or cross-project tags return `404`.

```bash
curl -sS -X PATCH \
  -H "Authorization: Bearer $TM_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"color":"#EF4444"}' \
  "$TM_BASE_URL/api/v1/tags/42"
```

Renaming or recoloring keeps the tag ID and all existing test-case
associations.

## Delete tag

`DELETE /api/v1/tags/{id}`

A successful deletion returns `{ "success": true }` with HTTP `200`.
Missing, cross-project, or already-deleted tags return `404`. Deleting a tag
removes its associations only; test cases, test runs, and results are
preserved.

```bash
curl -sS -X DELETE \
  -H "Authorization: Bearer $TM_TOKEN" \
  "$TM_BASE_URL/api/v1/tags/42"
```

---

## List test cases

`GET /api/v1/test-cases`

Optional query params (combine as needed):

- `folderId` — integer
- `status` — `DRAFT` \| `ACTUAL` \| `DEPRECATED`
- `priority` — `LOW` \| `MEDIUM` \| `HIGH` \| `CRITICAL`

Each item includes `id`, `publicNumber`, `publicId`, `projectCode`, `title`, `description`, `status`, `priority`, `folderId`, `createdAt`, `folder` (`id`, `name`), `tags` (`id`, `name`).

```bash
curl -sS -H "Authorization: Bearer $TM_TOKEN" \
  "$TM_BASE_URL/api/v1/test-cases?status=ACTUAL&folderId=1"
```

---

## Get test case

`GET /api/v1/test-cases/{id}`

Returns a single test case including `publicNumber`, `publicId`, `projectCode`, `steps`, `preconditions`, `postconditions`, `folder`, and `tags`.

```bash
curl -sS -H "Authorization: Bearer $TM_TOKEN" "$TM_BASE_URL/api/v1/test-cases/42"
```

---

## Create test case

`POST /api/v1/test-cases` — JSON body.

| Field | Notes |
|-------|--------|
| `title` | required |
| `description`, `preconditions`, `postconditions` | optional strings |
| `steps` | optional array of `{ "action": string, "data"?: string, "expected"?: string }`. Use `data` for concrete fixtures/inputs/endpoints/messages and `expected` for the step-level outcome. |
| `expectedResult` | optional string |
| `priority` | default `MEDIUM` |
| `status` | default `ACTUAL` |
| `folderId` | optional; must belong to the project |
| `tagIds` | optional int[]; tags must belong to the project. Resolve existing tag IDs with `GET /api/v1/tags` before applying tag rules below. |
| `position` | optional; if omitted, appends after last case in same folder |

```bash
curl -sS -X POST -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Login with valid user","folderId":1,"priority":"HIGH","steps":[{"action":"Open login page"}]}' \
  "$TM_BASE_URL/api/v1/test-cases"
```

---

## Update test case

`PATCH /api/v1/test-cases/{id}` — JSON body, all fields optional.

Same fields as create: `title`, `description`, `preconditions`, `postconditions`, `steps`, `expectedResult`, `priority`, `status`, `folderId`, `tagIds`. Only provided fields are updated.

```bash
curl -sS -X PATCH -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"status":"DEPRECATED","priority":"LOW"}' \
  "$TM_BASE_URL/api/v1/test-cases/42"
```

---

## Delete test case

`DELETE /api/v1/test-cases/{id}`

```bash
curl -sS -X DELETE -H "Authorization: Bearer $TM_TOKEN" "$TM_BASE_URL/api/v1/test-cases/42"
```

---

## List test runs

`GET /api/v1/test-runs`

Optional: `?status=IN_PROGRESS` (or any `TestRunStatus`).

Each run includes `publicNumber`, `publicId`, `projectCode`, `caseCount`, `creator.name`, `environment`, `source`, `startDate`, `endDate`, etc.

```bash
curl -sS -H "Authorization: Bearer $TM_TOKEN" "$TM_BASE_URL/api/v1/test-runs?status=IN_PROGRESS"
```

---

## Get test run

`GET /api/v1/test-runs/{id}`

Returns a single run with `publicNumber`, `publicId`, `projectCode`, `caseCount`, `creator.name`, `environment`, etc.

```bash
curl -sS -H "Authorization: Bearer $TM_TOKEN" "$TM_BASE_URL/api/v1/test-runs/10"
```

---

## Create test run

`POST /api/v1/test-runs`

Body: `{ "name": string, "description"?: string, "source"?: string (default "playwright"), "externalId"?: string, "environment"?: string }`

Environment is normalized against project environments when possible.

```bash
curl -sS -X POST -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Nightly","source":"ci","environment":"staging"}' \
  "$TM_BASE_URL/api/v1/test-runs"
```

---

## Delete test run

`DELETE /api/v1/test-runs/{id}`

```bash
curl -sS -X DELETE -H "Authorization: Bearer $TM_TOKEN" "$TM_BASE_URL/api/v1/test-runs/10"
```

---

## Add cases to a test run

`POST /api/v1/test-runs/{runId}/cases`

Body: `{ "testCaseIds": [1, 2, 3] }` or `{ "testCasePublicIds": ["WEB-1", "WEB-2"] }` — provide exactly one form. Already-present cases are skipped.

Response: `{ "added": 2, "skipped": 1, "cases": [ { "testRunCaseId", "testCaseId", "testCasePublicId" } ] }`

Use `testRunCaseId` when removing a case or posting a comment.

```bash
curl -sS -X POST -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"testCaseIds":[10,11,12]}' \
  "$TM_BASE_URL/api/v1/test-runs/5/cases"
```

Public-reference form:

```bash
curl -sS -X POST -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"testCasePublicIds":["WEB-1","WEB-2"]}' \
  "$TM_BASE_URL/api/v1/test-runs/5/cases"
```

---

## Remove case from a test run

`DELETE /api/v1/test-runs/{runId}/cases/{testRunCaseId}`

**Note:** `{testRunCaseId}` is the **TestRunCase** row id (from the add-cases response or `GET /api/v1/test-runs/{id}`), not the library `testCaseId`.

```bash
curl -sS -X DELETE -H "Authorization: Bearer $TM_TOKEN" \
  "$TM_BASE_URL/api/v1/test-runs/5/cases/99"
```

---

## Report results (batch)

`POST /api/v1/test-runs/{runId}/results`

Body: `{ "results": [ { ... }, ... ] }` (1–500 items).

Each result:

- If `testCaseId` is set: upserts that case in the run (mapped). Use project test case IDs from `GET /api/v1/test-cases`.
- If `testCasePublicId` is set: upserts the project-scoped case (mapped), for example `WEB-1`. It may be used instead of `testCaseId`; if both are set they must identify the same case.
- If neither `testCaseId` nor `testCasePublicId` is set: unmapped row (`testTitle` required, etc.).

```bash
curl -sS -X POST -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"results":[{"testCaseId":42,"testTitle":"x","status":"PASSED"}]}' \
  "$TM_BASE_URL/api/v1/test-runs/10/results"
```

Public-reference form:

```bash
curl -sS -X POST -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"results":[{"testCasePublicId":"WEB-1","testTitle":"x","status":"PASSED"}]}' \
  "$TM_BASE_URL/api/v1/test-runs/10/results"
```

Response includes `mapped`, `unmapped`, `errors`, and `cases` with
`testRunCaseId` for comments. HTTP 200 means the batch was processed, not that
every result was accepted. Always inspect `errors`; a non-empty array means the
offending results were skipped while other results may already have been
applied. Treat that response as a partial failure. Resolve the errors and
successfully resubmit the rejected results before reporting success or
completing the run.

---

## Complete test run

`POST /api/v1/test-runs/{runId}/complete`

Body: `{ "status": "COMPLETED" }` or `"CANCELLED"` (default `COMPLETED`).

```bash
curl -sS -X POST -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"status":"COMPLETED"}' \
  "$TM_BASE_URL/api/v1/test-runs/10/complete"
```

---

## Comment on a run case (optional screenshots)

`POST /api/v1/test-runs/{runId}/cases/{testRunCaseId}/comments`

**Important:** `{testRunCaseId}` is the **TestRunCase** row id (from `/results` response `cases[].testRunCaseId` or UI), not the library `testCaseId`.

Body: `{ "content": string, "attachments"?: [ { "url", "filename", "contentType", "size" } ] }`

---

## Upload image (for attachments)

`POST /api/v1/upload` — `multipart/form-data` field `file` (JPEG/PNG/WebP/GIF, max 5 MB).

Returns `{ "url", "filename", "contentType", "sizeBytes" }` — use `url` in comment `attachments`.

---

## Typical flows

**Create cases directly**

1. `GET /api/v1/folders` → pick `folderId`
2. `POST /api/v1/test-cases` for each case

**Create cases, then a run, then report**

1. `GET /api/v1/folders` → pick `folderId`
2. `POST /api/v1/test-cases` for each case
3. `POST /api/v1/test-runs` → `runId`
4. `POST /api/v1/test-runs/{runId}/results` with `{ testCaseId, testTitle, status }` or `{ testCasePublicId, testTitle, status }` per case
5. Inspect `errors`; resolve and resubmit every rejected result until `errors` is empty
6. `POST /api/v1/test-runs/{runId}/complete`

---

## Tips

- **Be specific about folder names** — list folders first if you need to resolve a name to an ID.
- **Resolve IDs before mutations** — list folders or tags first, and confirm the selected item belongs to the token-scoped project before deleting or editing it.
- **Reference case IDs when you know them** — e.g. "mark TC-42 as FAILED" is faster than describing the case.
- **Apply the `api` tag only for direct endpoint tests** — when creating test cases that call API endpoints directly, run `GET /api/v1/tags`, find the existing tag named `api`, and include its ID in `tagIds`. Do not create the tag or apply it to UI/manual tests unless the user explicitly asks.
- **Apply the `smoke` tag sparingly** — use `smoke` for the smallest must-pass set proving the core app is accessible and usable. Do not tag every happy path as `smoke`. When needed, run `GET /api/v1/tags`, find the existing tag named `smoke`, and include its ID in `tagIds`. Do not create the tag if it is missing.
- **Token is per-project** — if you work across multiple projects, generate a separate token for each and rerun the installer when switching `TM_BASE_URL`.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `TM_TOKEN` is empty after sourcing `~/.tm-config` | Credential lookup failed. Rerun the installer and paste a valid token when prompted. |
| Installer exits with a missing-dependency error | Install `jq` (plus `curl`/`tar`/`shasum` or `sha256sum`, which normally already ship with macOS and Git for Windows) and rerun. |
| Missing macOS `security` command | Run from a normal macOS terminal where `/usr/bin/security` is available, then rerun the installer. |
| Windows PowerShell or Credential Manager errors | Run from Windows Git Bash with `powershell.exe` available and Credential Manager enabled. |
| Windows credential lookup is slow | The generated config starts PowerShell to read Credential Manager; this startup cost is expected. |
| Linux or WSL installer failure | Linux and WSL are unsupported by the installer; it exits before installing skill docs or changing config. |
| `401 Unauthorized` | Stored token is invalid, expired, or belongs to a different project. Generate a new token, rerun the installer, and paste the new token when it asks whether to replace the stored token. |
| `404 Folder not found` | The `folderId` doesn't belong to this token's project — ask to "list folders" first |
| `404 Tag not found` | The tag ID doesn't belong to this token's project — ask to "list tags" first |
| `400 Invalid tag IDs` | Tag IDs must belong to the project — check Project Settings → Tags |
| Wrong URL constructed | Make sure `TM_BASE_URL` has no trailing slash and matches your actual deployment URL. Rerun the installer after base URL changes so the credential target is updated. |
