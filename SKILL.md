# TestManagement AI Skill

Use this skill to manage test cases and test runs in a TestManagement project directly from your AI tool — no browser needed.

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
2. Go to **Project Settings → API Tokens**
3. Click **New Token**, give it a name (e.g. `ai-local`), select a "Run as" member
4. Copy the token — it starts with `tm_` and is shown **only once**

### 2. Run the installer

```bash
curl -fsSL https://raw.githubusercontent.com/JernejMrvar/tm-ai-skill/main/install.sh | bash
```

The installer supports macOS and Windows Git Bash. It prompts for the `tm_...` token through `/dev/tty`, stores it in the OS credential store, and writes `~/.tm-config` with non-secret exports and lookup logic. If a token is already stored, the installer asks for a replacement token and treats blank input as "reuse the existing token". Do not manually write plaintext `TM_TOKEN` values into `~/.tm-config`.

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
- Folder deletion may not exist in v1; if `DELETE /api/v1/folders/{id}` returns 404, report that and leave empty folders rather than using unsupported workarounds.

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

Returns folders with `testCaseCount` per folder.

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

---

## List tags

`GET /api/v1/tags`

Returns all tags in the project ordered by name.

```bash
curl -sS -H "Authorization: Bearer $TM_TOKEN" "$TM_BASE_URL/api/v1/tags"
```

Response shape: `{ "tags": [ { "id", "name" } ] }`

---

## List test cases

`GET /api/v1/test-cases`

Optional query params (combine as needed):

- `folderId` — integer
- `status` — `DRAFT` \| `ACTUAL` \| `DEPRECATED`
- `priority` — `LOW` \| `MEDIUM` \| `HIGH` \| `CRITICAL`

Each item includes `id`, `title`, `description`, `status`, `priority`, `folderId`, `createdAt`, `folder` (`id`, `name`), `tags` (`id`, `name`).

```bash
curl -sS -H "Authorization: Bearer $TM_TOKEN" \
  "$TM_BASE_URL/api/v1/test-cases?status=ACTUAL&folderId=1"
```

---

## Get test case

`GET /api/v1/test-cases/{id}`

Returns a single test case including `steps`, `preconditions`, `postconditions`, `folder`, and `tags`.

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

Each run includes `caseCount`, `creator.name`, `environment`, `source`, `startDate`, `endDate`, etc.

```bash
curl -sS -H "Authorization: Bearer $TM_TOKEN" "$TM_BASE_URL/api/v1/test-runs?status=IN_PROGRESS"
```

---

## Get test run

`GET /api/v1/test-runs/{id}`

Returns a single run with `caseCount`, `creator.name`, `environment`, etc.

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

Body: `{ "testCaseIds": [1, 2, 3] }` — use IDs from `GET /api/v1/test-cases`. Already-present cases are skipped.

Response: `{ "added": 2, "skipped": 1, "cases": [ { "testRunCaseId", "testCaseId" } ] }`

Use `testRunCaseId` when removing a case or posting a comment.

```bash
curl -sS -X POST -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"testCaseIds":[10,11,12]}' \
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
- If `testCaseId` is omitted: unmapped row (`testTitle` required, etc.).

```bash
curl -sS -X POST -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"results":[{"testCaseId":42,"testTitle":"x","status":"PASSED"}]}' \
  "$TM_BASE_URL/api/v1/test-runs/10/results"
```

Response includes `mapped`, `unmapped`, `errors`, and `cases` with `testRunCaseId` for comments.

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
4. `POST /api/v1/test-runs/{runId}/results` with `{ testCaseId, testTitle, status }` per case
5. `POST /api/v1/test-runs/{runId}/complete`

---

## Tips

- **Be specific about folder names** — list folders first if you need to resolve a name to an ID.
- **Reference case IDs when you know them** — e.g. "mark TC-42 as FAILED" is faster than describing the case.
- **Apply the `api` tag only for direct endpoint tests** — when creating test cases that call API endpoints directly, run `GET /api/v1/tags`, find the existing tag named `api`, and include its ID in `tagIds`. Do not create the tag or apply it to UI/manual tests unless the user explicitly asks.
- **Apply the `smoke` tag sparingly** — use `smoke` for the smallest must-pass set proving the core app is accessible and usable. Do not tag every happy path as `smoke`. When needed, run `GET /api/v1/tags`, find the existing tag named `smoke`, and include its ID in `tagIds`. Do not create the tag if it is missing.
- **Token is per-project** — if you work across multiple projects, generate a separate token for each and rerun the installer when switching `TM_BASE_URL`.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `TM_TOKEN` is empty after sourcing `~/.tm-config` | Credential lookup failed. Rerun the installer and paste a valid token when prompted. |
| Missing macOS `security` command | Run from a normal macOS terminal where `/usr/bin/security` is available, then rerun the installer. |
| Windows PowerShell or Credential Manager errors | Run from Windows Git Bash with `powershell.exe` available and Credential Manager enabled. |
| Windows credential lookup is slow | The generated config starts PowerShell to read Credential Manager; this startup cost is expected. |
| Linux or WSL installer failure | Linux and WSL are unsupported by the installer; it exits before installing skill docs or changing config. |
| `401 Unauthorized` | Stored token is invalid, expired, or belongs to a different project. Generate a new token, rerun the installer, and paste the new token when it asks whether to replace the stored token. |
| `404 Folder not found` | The `folderId` doesn't belong to this token's project — ask to "list folders" first |
| `400 Invalid tag IDs` | Tag IDs must belong to the project — check Project Settings → Tags |
| Wrong URL constructed | Make sure `TM_BASE_URL` has no trailing slash and matches your actual deployment URL. Rerun the installer after base URL changes so the credential target is updated. |
