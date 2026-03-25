# TestManagement AI Skill

Use this skill to manage test cases and test runs in a TestManagement project directly from your AI tool — no browser needed.

## Before making any API call

Run the following to load credentials, then check `TM_TOKEN` is set:

```bash
source ~/.tm-config 2>/dev/null
```

If `TM_TOKEN` is empty after sourcing, tell the user to open `~/.tm-config` and add their token and base URL, then try again.

---

## Setup

### 1. Generate an API token

1. Open your project in the app
2. Go to **Project Settings → API Tokens**
3. Click **New Token**, give it a name (e.g. `ai-local`), select a "Run as" member
4. Copy the token — it starts with `tm_` and is shown **only once**

### 2. Set environment variables

```bash
export TM_TOKEN="tm_your_token_here"
export TM_BASE_URL="https://your-app.vercel.app"   # or http://localhost:3000 for local dev
```

Every request must include:

```http
Authorization: Bearer tm_xxxxxxxx
```

The token implicitly scopes all operations to its project — there is no `projectId` query param on v1 routes.

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

## Create test case

`POST /api/v1/test-cases` — JSON body.

| Field | Notes |
|-------|--------|
| `title` | required |
| `description`, `preconditions`, `postconditions` | optional strings |
| `steps` | optional array of `{ "action": string, "data"?: string, "expected"?: string }` |
| `expectedResult` | optional string |
| `priority` | default `MEDIUM` |
| `status` | default `ACTUAL` |
| `folderId` | optional; must belong to the project |
| `tagIds` | optional int[]; tags must belong to the project |
| `position` | optional; if omitted, appends after last case in same folder |

```bash
curl -sS -X POST -H "Authorization: Bearer $TM_TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Login with valid user","folderId":1,"priority":"HIGH","steps":[{"action":"Open login page"}]}' \
  "$TM_BASE_URL/api/v1/test-cases"
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
- **Token is per-project** — if you work across multiple projects, generate a separate token for each and switch `TM_TOKEN` accordingly.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `401 Unauthorized` | Token is invalid or `TM_TOKEN` is not exported in the current shell |
| `404 Folder not found` | The `folderId` doesn't belong to this token's project — ask to "list folders" first |
| `400 Invalid tag IDs` | Tag IDs must belong to the project — check Project Settings → Tags |
| Wrong URL constructed | Make sure `TM_BASE_URL` has no trailing slash and matches your actual deployment URL |
