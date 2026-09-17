#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_FILE="$ROOT_DIR/SKILL.md"

pass_count=0

assert_contains() {
  local needle="$1"
  local label="$2"

  if ! grep -Fq "$needle" "$SKILL_FILE"; then
    printf 'not ok - %s\nmissing: %s\n' "$label" "$needle" >&2
    exit 1
  fi

  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

assert_before() {
  local earlier="$1"
  local later="$2"
  local label="$3"
  local earlier_line later_line

  earlier_line="$(grep -nF "$earlier" "$SKILL_FILE" | head -n 1 | cut -d: -f1)"
  later_line="$(grep -nF "$later" "$SKILL_FILE" | head -n 1 | cut -d: -f1)"

  if [ -z "$earlier_line" ] || [ -z "$later_line" ] || [ "$earlier_line" -ge "$later_line" ]; then
    printf 'not ok - %s\nexpected "%s" before "%s"\n' "$label" "$earlier" "$later" >&2
    exit 1
  fi

  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

assert_contains '## Mandatory API-only guardrail' 'skill defines the API-only guardrail'
assert_contains 'Never open or control a browser to perform a TestManagement operation.' 'skill prohibits browser control'
assert_contains 'Never call the browser/session API routes under `/api/*`.' 'skill prohibits session API routes'
assert_contains 'Do not fall back to the browser, the UI, session cookies, or a non-v1 endpoint.' 'skill stops instead of changing transports'
assert_contains 'make no mutations and ask the user to configure the correct project token' 'skill prevents writes when project context looks wrong'
assert_contains 'Audit Log as `API: <token name>`' 'skill defines expected API attribution'
assert_contains 'mismatch rejects only that result' 'skill defines per-result batch rejection'
assert_contains 'returns HTTP 200 with details in the response `errors` array' 'skill warns that batch errors use HTTP 200'
assert_contains 'before reporting success or' 'skill blocks success reporting after partial failure'
assert_contains 'completing the run' 'skill blocks run completion after partial failure'
assert_before '## Mandatory API-only guardrail' '## Before making any API call' 'guardrail appears before operational instructions'

assert_contains '## Personal API keys and deliberate project selection' 'skill defines the personal-key project-selection section'
assert_contains 'send an explicit' 'skill requires an explicit project header'
assert_contains '`X-TM-Project-Id: <id>` header on every subsequent project-scoped request' 'skill requires the project header on every request, even with one project'
assert_contains 'ask once which project before making any request that would mutate data' 'skill asks once and blocks mutations when ambiguous'
assert_contains 'Send zero mutations until the project is resolved' 'skill blocks mutations until project selection resolves'
assert_contains 'Never choose a project by list order' 'skill forbids inferring project from list order'
assert_contains 'a repository/folder name match' 'skill forbids inferring project from name matching'
assert_contains 'retry it against a different project, account, or the browser to force a' 'skill forbids retrying a blocked operation against another project/account/browser'
assert_before '## Personal API keys and deliberate project selection' '## Before making any API call' 'project-selection guidance appears before operational instructions'
assert_before '## Mandatory API-only guardrail' '## Personal API keys and deliberate project selection' 'core guardrail appears before project-selection guidance'

printf '1..%d\n' "$pass_count"
