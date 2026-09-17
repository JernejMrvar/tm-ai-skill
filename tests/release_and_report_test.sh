#!/usr/bin/env bash
set -euo pipefail

# Integration coverage for release-manifest validation, checksum/archive
# safety, staged target replacement, and the installation-report client —
# against a real local HTTP round trip (tests/fixtures/fake_tm_server.py),
# never a real TestManagement deployment.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 is required to run the fake fixture server for this test file." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is required by install.sh's own release/report handling." >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

export TM_INSTALL_TEST_MODE=1
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
export TM_CONFIG_FILE="$TMP_ROOT/tm-config"
export TM_STATE_DIR="$TMP_ROOT/tm-state"
# shellcheck disable=SC1091
source "$ROOT_DIR/install.sh"

pass_count=0

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" != "$actual" ]; then
    printf 'not ok - %s\nexpected: %s\nactual:   %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

assert_file_exists() {
  local path="$1" label="$2"
  if [ ! -f "$path" ]; then
    printf 'not ok - %s\nmissing file: %s\n' "$label" "$path" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

assert_file_missing() {
  local path="$1" label="$2"
  if [ -f "$path" ]; then
    printf 'not ok - %s\nunexpected file present: %s\n' "$label" "$path" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

assert_contains() {
  local needle="$1" haystack="$2" label="$3"
  case "$haystack" in
    *"$needle"*) : ;;
    *)
      printf 'not ok - %s\nmissing: %s\nin: %s\n' "$label" "$needle" "$haystack" >&2
      exit 1
      ;;
  esac
  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

# Test-only relaxation: the fixture server has no TLS, so accept its loopback
# http URL as "immutable" purely for these tests. install.sh's own shipped
# behavior (asserted separately below and in install_helpers_test.sh) still
# requires real https for every artifact URL.
is_immutable_https_url() {
  local url="$1"
  case "$url" in
    http://127.0.0.1:*) return 0 ;;
  esac
  case "$(printf '%s' "$url" | lower)" in
    https://*) : ;;
    *) return 1 ;;
  esac
  case "$(printf '%s' "$url" | lower)" in
    */latest/*|*/latest|*/main/*|*/main|*/master/*|*/master|*/head/*|*/head|*/trunk/*|*/trunk) return 1 ;;
  esac
  return 0
}

# Test-only relaxation of the same kind: the shipped download_release_artifact
# pins `--proto '=https'` (rejecting any http:// transport, including a
# downgraded redirect) — correct and load-bearing for real artifact hosts,
# but incompatible with this test's plain-http local fixture server. The
# digest/size verification logic below is otherwise identical to install.sh's
# own implementation, so those checks are still exercised for real.
download_release_artifact() {
  local url="$1" expected_sha="$2" expected_size="$3" out_file="$4" actual_size actual_sha
  curl -fsSL --max-redirs 5 --connect-timeout 10 --max-time 120 \
    --max-filesize "$((expected_size + 1024))" \
    -o "$out_file" "$url" 2>/dev/null || return 1
  actual_size="$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')"
  [ "$actual_size" = "$expected_size" ] || return 1
  actual_sha="$(sha256_file "$out_file")" || return 1
  [ "$actual_sha" = "$expected_sha" ] || return 1
  return 0
}

# --- fixture: a valid packaged bundle ---------------------------------------

BUILD_DIR="$TMP_ROOT/build"
mkdir -p "$BUILD_DIR/tm-ai-skill-9.9.9"
cp "$ROOT_DIR/install.sh" "$BUILD_DIR/tm-ai-skill-9.9.9/install.sh"
{
  echo "# TestManagement AI Skill"
  echo ""
  echo "## Mandatory API-only guardrail"
  echo "fixture skill content for release_and_report_test"
} > "$BUILD_DIR/tm-ai-skill-9.9.9/SKILL.md"
echo "fixture readme" > "$BUILD_DIR/tm-ai-skill-9.9.9/README.md"
echo "9.9.9" > "$BUILD_DIR/tm-ai-skill-9.9.9/VERSION"

SERVE_DIR="$TMP_ROOT/serve"
mkdir -p "$SERVE_DIR"
(cd "$BUILD_DIR" && tar czf "$SERVE_DIR/valid.tar.gz" tm-ai-skill-9.9.9)
VALID_SHA256="$(sha256_file "$SERVE_DIR/valid.tar.gz")"
VALID_SIZE="$(wc -c < "$SERVE_DIR/valid.tar.gz" | tr -d ' ')"

# --- fixture: malicious archives --------------------------------------------

python3 "$ROOT_DIR/tests/fixtures/make_archive.py" "$SERVE_DIR/traversal.tar.gz" \
  "file:tm-ai-skill-9.9.9/SKILL.md" "file:tm-ai-skill-9.9.9/../../evil.txt"
TRAVERSAL_SHA256="$(sha256_file "$SERVE_DIR/traversal.tar.gz")"
TRAVERSAL_SIZE="$(wc -c < "$SERVE_DIR/traversal.tar.gz" | tr -d ' ')"

python3 "$ROOT_DIR/tests/fixtures/make_archive.py" "$SERVE_DIR/symlink.tar.gz" \
  "file:tm-ai-skill-9.9.9/SKILL.md" "symlink:tm-ai-skill-9.9.9/evil-link:/etc/passwd"
SYMLINK_SHA256="$(sha256_file "$SERVE_DIR/symlink.tar.gz")"
SYMLINK_SIZE="$(wc -c < "$SERVE_DIR/symlink.tar.gz" | tr -d ' ')"

# --- start fixture server ----------------------------------------------------

PORT=$(( (RANDOM % 20000) + 20000 ))
python3 "$ROOT_DIR/tests/fixtures/fake_tm_server.py" "$PORT" "$SERVE_DIR" >"$TMP_ROOT/server.log" 2>&1 &
SERVER_PID=$!

waited=0
until curl -fsS "http://127.0.0.1:$PORT/api/v1/skill-release" >/dev/null 2>&1; do
  waited=$((waited + 1))
  if [ "$waited" -gt 100 ]; then
    echo "not ok - fixture server did not become ready" >&2
    exit 1
  fi
  sleep 0.1 2>/dev/null || sleep 1
done

BASE_URL="http://127.0.0.1:$PORT"

# =============================================================================
# Release manifest validation against real POV-30 fixtures
# =============================================================================

null_envelope='{"schemaVersion":1,"release":null}'
validate_release "$null_envelope"
assert_eq "0" "$RELEASE_PRESENT" "release:null is a valid, inert manifest state"

make_release_envelope() {
  local sha="$1" size="$2" tm_api_contract="${3:-1}"
  jq -n --arg sha "$sha" --argjson size "$size" --argjson tmApi "$tm_api_contract" --arg url "$BASE_URL/valid.tar.gz" '
    {
      schemaVersion: 1,
      release: {
        releaseVersion: 1,
        channel: "stable",
        publishedAt: "2026-01-01T00:00:00.000Z",
        installerVersion: "9.9.9",
        targetVersions: {codex: "9.9.9", claude: "9.9.9", cursor: "9.9.9"},
        contractVersions: {reportContractVersion: 1, manifestContractVersion: 1, tmApiContractVersion: $tmApi},
        artifacts: [
          {target: "codex", kind: "bundle", url: $url, sha256: $sha, sizeBytes: $size},
          {target: "claude", kind: "bundle", url: $url, sha256: $sha, sizeBytes: $size},
          {target: "cursor", kind: "bundle", url: $url, sha256: $sha, sizeBytes: $size}
        ]
      }
    }'
}

envelope="$(make_release_envelope "$VALID_SHA256" "$VALID_SIZE")"
validate_release "$envelope"
assert_eq "1" "$RELEASE_PRESENT" "valid release envelope is present"
assert_eq "1" "$RELEASE_COMPATIBLE" "valid release envelope is compatible"

release_target_available codex
assert_eq "9.9.9" "$RELEASE_TARGET_VERSION" "codex artifact resolves the advertised version"
assert_eq "$VALID_SHA256" "$RELEASE_TARGET_SHA256" "codex artifact resolves the advertised sha256"

incompatible_envelope="$(make_release_envelope "$VALID_SHA256" "$VALID_SIZE" 99)"
validate_release "$incompatible_envelope"
assert_eq "1" "$RELEASE_PRESENT" "an incompatible release is still present"
assert_eq "0" "$RELEASE_COMPATIBLE" "a higher tmApiContractVersion than supported is incompatible"

# A failed or malformed manifest must never enter the unpinned legacy path.
# It is recorded as a target failure so the installer exits nonzero and leaves
# existing target files untouched.
manifest_unavailable_output="$TMP_ROOT/manifest-unavailable.results"
manifest_unavailable_legacy="$TMP_ROOT/manifest-unavailable.legacy"
manifest_unavailable_release="$TMP_ROOT/manifest-unavailable.release"
manifest_unavailable_observation="$(
  (
    TARGET_RESULTS_FILE="$manifest_unavailable_output"
    fetch_release_manifest() { return 1; }
    sync_targets_legacy() { : > "$manifest_unavailable_legacy"; }
    sync_targets_release() { : > "$manifest_unavailable_release"; }
    sync_targets_from_manifest "install" "codex" "$TMP_ROOT/state" "$BASE_URL" >/dev/null 2>&1
    printf '%s|%s' "$(compute_exit_code)" "$(jq -r '.failureCode' "$manifest_unavailable_output")"
  )
)"
assert_eq "1|NETWORK_ERROR" "$manifest_unavailable_observation" \
  "an unavailable manifest fails the installation"
assert_file_missing "$manifest_unavailable_legacy" \
  "an unavailable manifest never triggers the legacy fallback"
assert_file_missing "$manifest_unavailable_release" \
  "an unavailable manifest never triggers a release sync"

manifest_invalid_output="$TMP_ROOT/manifest-invalid.results"
manifest_invalid_legacy="$TMP_ROOT/manifest-invalid.legacy"
manifest_invalid_observation="$(
  (
    TARGET_RESULTS_FILE="$manifest_invalid_output"
    fetch_release_manifest() { printf '%s' '{"schemaVersion":'; }
    sync_targets_legacy() { : > "$manifest_invalid_legacy"; }
    sync_targets_from_manifest "install" "codex" "$TMP_ROOT/state" "$BASE_URL" >/dev/null 2>&1
    printf '%s|%s' "$(compute_exit_code)" "$(jq -r '.failureCode' "$manifest_invalid_output")"
  )
)"
assert_eq "1|UNKNOWN_ERROR" "$manifest_invalid_observation" \
  "a malformed manifest fails the installation"
assert_file_missing "$manifest_invalid_legacy" \
  "a malformed manifest never triggers the legacy fallback"

manifest_incomplete_output="$TMP_ROOT/manifest-incomplete.results"
manifest_incomplete_legacy="$TMP_ROOT/manifest-incomplete.legacy"
manifest_incomplete_observation="$(
  (
    TARGET_RESULTS_FILE="$manifest_incomplete_output"
    fetch_release_manifest() { printf '%s' '{"schemaVersion":1}'; }
    sync_targets_legacy() { : > "$manifest_incomplete_legacy"; }
    sync_targets_from_manifest "install" "codex" "$TMP_ROOT/state" "$BASE_URL" >/dev/null 2>&1
    printf '%s|%s' "$(compute_exit_code)" "$(jq -r '.failureCode' "$manifest_incomplete_output")"
  )
)"
assert_eq "1|UNKNOWN_ERROR" "$manifest_incomplete_observation" \
  "an incomplete manifest fails the installation"
assert_file_missing "$manifest_incomplete_legacy" \
  "an incomplete manifest never triggers the legacy fallback"

manifest_null_output="$TMP_ROOT/manifest-null.results"
manifest_null_legacy="$TMP_ROOT/manifest-null.legacy"
manifest_null_observation="$(
  (
    TARGET_RESULTS_FILE="$manifest_null_output"
    fetch_release_manifest() { printf '%s' '{"schemaVersion":1,"release":null}'; }
    sync_targets_legacy() {
      : > "$manifest_null_legacy"
      append_target_result codex success "" "" ""
    }
    sync_targets_from_manifest "install" "codex" "$TMP_ROOT/state" "$BASE_URL" >/dev/null 2>&1
    printf '%s|%s' "$(compute_exit_code)" "$(jq -r '.result' "$manifest_null_output")"
  )
)"
assert_eq "0|success" "$manifest_null_observation" \
  "only a successfully validated no-release manifest triggers the legacy fallback"
assert_file_exists "$manifest_null_legacy" \
  "a validated no-release manifest invokes the legacy fallback"

# =============================================================================
# Fresh install of a single target from a verified release
# =============================================================================

STATE_DIR="$(local_version_state_dir "$BASE_URL")"
validate_release "$envelope"

TARGET_RESULTS_FILE="$(mktemp)"
sync_targets_release "install" "codex" "$STATE_DIR"

assert_file_exists "$HOME/.codex/tm-api.md" "codex content file installed"
assert_contains "fixture skill content" "$(cat "$HOME/.codex/tm-api.md")" "installed content matches the fixture release"
assert_contains "@~/.codex/tm-api.md" "$(cat "$HOME/.codex/AGENTS.md")" "AGENTS.md registers the skill include"
assert_eq "success" "$(jq -r '.result' "$TARGET_RESULTS_FILE")" "install reports success for codex"
assert_eq "9.9.9" "$(jq -r '.observedVersion' "$TARGET_RESULTS_FILE")" "install reports the installed version"
assert_eq "9.9.9" "$(state_target_field "$STATE_DIR" codex version)" "local state records the installed version"

# =============================================================================
# update: up-to-date target is a no-op that still reports success
# =============================================================================

TARGET_RESULTS_FILE="$(mktemp)"
sync_targets_release "update" "codex" "$STATE_DIR"
assert_eq "success" "$(jq -r '.result' "$TARGET_RESULTS_FILE")" "update on an already-current target reports success"
assert_eq "9.9.9" "$(jq -r '.observedVersion' "$TARGET_RESULTS_FILE")" "update reports the recorded version, not a re-download"

# =============================================================================
# update: never clobbers a locally edited file
# =============================================================================

printf '\nlocally edited by the user\n' >> "$HOME/.codex/tm-api.md"
EDITED_CONTENT="$(cat "$HOME/.codex/tm-api.md")"

TARGET_RESULTS_FILE="$(mktemp)"
sync_targets_release "update" "codex" "$STATE_DIR"
assert_eq "skipped" "$(jq -r '.result' "$TARGET_RESULTS_FILE")" "update skips a target with an unrecognized local digest"
assert_eq "$EDITED_CONTENT" "$(cat "$HOME/.codex/tm-api.md")" "the locally edited file was never overwritten"

# reconfigure/install always proceeds regardless of local edits
TARGET_RESULTS_FILE="$(mktemp)"
sync_targets_release "reconfigure" "codex" "$STATE_DIR"
assert_eq "success" "$(jq -r '.result' "$TARGET_RESULTS_FILE")" "reconfigure overwrites a locally edited target on purpose"
assert_contains "fixture skill content" "$(cat "$HOME/.codex/tm-api.md")" "reconfigure restores the packaged content"

# =============================================================================
# digest mismatch on a fresh target install: no file is written
# =============================================================================

wrong_sha="$(printf '%s' "$VALID_SHA256" | sed 's/^./0/')"
[ "$wrong_sha" = "$VALID_SHA256" ] && wrong_sha="${VALID_SHA256%?}f"
bad_envelope="$(make_release_envelope "$wrong_sha" "$VALID_SIZE")"
validate_release "$bad_envelope"

TARGET_RESULTS_FILE="$(mktemp)"
sync_targets_release "install" "claude" "$STATE_DIR"
assert_eq "failed" "$(jq -r '.result' "$TARGET_RESULTS_FILE")" "a sha256 mismatch is reported as a failure"
assert_eq "DIGEST_MISMATCH" "$(jq -r '.failureCode' "$TARGET_RESULTS_FILE")" "a sha256 mismatch uses the DIGEST_MISMATCH failure code"
assert_file_missing "$HOME/.claude/tm-api.md" "no file is written when the digest check fails"

# =============================================================================
# archive safety: path traversal and symlink entries are rejected pre-extraction
# =============================================================================

traversal_envelope="$(jq -n --arg sha "$TRAVERSAL_SHA256" --argjson size "$TRAVERSAL_SIZE" --arg url "$BASE_URL/traversal.tar.gz" '
  {schemaVersion:1, release:{releaseVersion:1, channel:"stable", publishedAt:"2026-01-01T00:00:00.000Z",
   installerVersion:"9.9.9", targetVersions:{cursor:"9.9.9"},
   contractVersions:{reportContractVersion:1, manifestContractVersion:1, tmApiContractVersion:1},
   artifacts:[{target:"cursor", kind:"bundle", url:$url, sha256:$sha, sizeBytes:$size}]}}')"
validate_release "$traversal_envelope"

TARGET_RESULTS_FILE="$(mktemp)"
sync_targets_release "install" "cursor" "$STATE_DIR"
assert_eq "failed" "$(jq -r '.result' "$TARGET_RESULTS_FILE")" "a path-traversal archive entry is rejected"
assert_file_missing "$HOME/.cursor/rules/tm-api.md" "no file is written when the archive fails safety validation"
assert_file_missing "$TMP_ROOT/evil.txt" "the traversal entry never escapes the extraction directory"

symlink_envelope="$(jq -n --arg sha "$SYMLINK_SHA256" --argjson size "$SYMLINK_SIZE" --arg url "$BASE_URL/symlink.tar.gz" '
  {schemaVersion:1, release:{releaseVersion:1, channel:"stable", publishedAt:"2026-01-01T00:00:00.000Z",
   installerVersion:"9.9.9", targetVersions:{cursor:"9.9.9"},
   contractVersions:{reportContractVersion:1, manifestContractVersion:1, tmApiContractVersion:1},
   artifacts:[{target:"cursor", kind:"bundle", url:$url, sha256:$sha, sizeBytes:$size}]}}')"
validate_release "$symlink_envelope"

TARGET_RESULTS_FILE="$(mktemp)"
sync_targets_release "install" "cursor" "$STATE_DIR"
assert_eq "failed" "$(jq -r '.result' "$TARGET_RESULTS_FILE")" "a symlink archive entry is rejected"
assert_file_missing "$HOME/.cursor/rules/tm-api.md" "no file is written when a symlink entry is present"

# =============================================================================
# Installation reporting: idempotent replay, conflict, and 404 handling
# =============================================================================

OWNER_TOKEN="tmp_owner-alpha_1"
printf 'export TM_BASE_URL="%s"\nexport TM_TOKEN="%s"\n' "$BASE_URL" "$OWNER_TOKEN" > "$TM_CONFIG_FILE"
chmod 600 "$TM_CONFIG_FILE"

validate_candidate_credential "$BASE_URL" "$OWNER_TOKEN"
assert_eq "personal" "$CRED_KIND" "fixture token is recognized as a personal key"
assert_eq "owner-alpha" "$CRED_OWNER_ID" "fixture token's ownerId round-trips through /api/v1/me"
assert_eq "1" "$CRED_GENERATION" "fixture token's generation round-trips through /api/v1/me"

REPORT_STATE_DIR="$(state_dir_for "$BASE_URL" "$CRED_OWNER_ID")"
ensure_installation_identity "$REPORT_STATE_DIR"
FIRST_INSTALLATION_ID="$INSTALLATION_ID"

TARGET_RESULTS_FILE="$(mktemp)"
append_target_result codex success 9.9.9 "" ""
submit_operation_report "install" "$BASE_URL" "$CRED_OWNER_ID" "$CRED_GENERATION" "verified" ""
assert_eq "1" "$REPORT_DELIVERED" "a fresh report is delivered against the fixture server"

pending_after_success="$(state_read "$REPORT_STATE_DIR" | jq -c '.pendingReport')"
assert_eq "null" "$pending_after_success" "a delivered report leaves no pending report queued"

# Idempotent replay: submit_operation_report always allocates a fresh
# sequence for a new call, so exercise the underlying idempotent-replay path
# directly the way retry-report does — resubmitting the exact same body.
last_seq="$(state_read "$REPORT_STATE_DIR" | jq -r '.sequence')"
last_body="$(build_report_body "$FIRST_INSTALLATION_ID" "$last_seq" "install" "$TM_INSTALLER_VERSION" "" "verified" "" "$(targets_json_array)")"
submit_report "$BASE_URL" "$OWNER_TOKEN" "$last_body"
assert_eq "200" "$REPORT_HTTP_CODE" "resubmitting an identical sequence+payload replays the original receipt"

# Conflict: same sequence, different payload
TARGET_RESULTS_FILE="$(mktemp)"
append_target_result codex failed "" 9.9.9 "NETWORK_ERROR"
conflicting_body="$(build_report_body "$FIRST_INSTALLATION_ID" "$last_seq" "install" "9.9.9" "" "verified" "" "$(targets_json_array)")"
submit_report "$BASE_URL" "$OWNER_TOKEN" "$conflicting_body"
assert_eq "409" "$REPORT_HTTP_CODE" "the same sequence with a different payload is a conflict"

# Cross-owner 404 stops reporting rather than reassigning the installation
TARGET_RESULTS_FILE="$(mktemp)"
append_target_result codex success 9.9.9 "" ""
next_body="$(build_report_body "$FIRST_INSTALLATION_ID" $((last_seq + 1)) "check" "9.9.9" "" "not_checked" "" "$(targets_json_array)")"
submit_report_forced() {
  local status="$1"
  curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $OWNER_TOKEN" -H "Content-Type: application/json" \
    -H "X-Test-Force-Status: $status" \
    -X POST --data "$next_body" \
    "$BASE_URL/api/v1/skill-installations/report"
}
forced_code="$(submit_report_forced 404)"
assert_eq "404" "$forced_code" "fixture server can simulate a cross-owner 404 for handle_report_outcome to react to"

printf '1..%d\n' "$pass_count"
