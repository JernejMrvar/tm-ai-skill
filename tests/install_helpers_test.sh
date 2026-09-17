#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export TM_INSTALL_TEST_MODE=1
# shellcheck disable=SC1091
source "$ROOT_DIR/install.sh"

pass_count=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [ "$expected" != "$actual" ]; then
    printf 'not ok - %s\nexpected: %s\nactual:   %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi

  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

assert_contains() {
  local needle="$1"
  local file="$2"
  local label="$3"

  if ! grep -Fq "$needle" "$file"; then
    printf 'not ok - %s\nmissing: %s\nfile: %s\n' "$label" "$needle" "$file" >&2
    exit 1
  fi

  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  local label="$3"

  if grep -Fq "$needle" "$file"; then
    printf 'not ok - %s\nunexpected: %s\nfile: %s\n' "$label" "$needle" "$file" >&2
    exit 1
  fi

  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

assert_text_contains() {
  local needle="$1"
  local text="$2"
  local label="$3"

  if [[ "$text" != *"$needle"* ]]; then
    printf 'not ok - %s\nmissing: %s\ntext: %s\n' "$label" "$needle" "$text" >&2
    exit 1
  fi

  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

config="$TMP_DIR/config"
redacted="$TMP_DIR/redacted"

{
  printf 'TM_BASE_URL=https://example.test/// # comment\n'
  printf 'export QUOTED_BASE_URL = "https://quoted.example/#keep"\n'
  printf "export SINGLE_BASE_URL='https://single.example/#keep'\n"
  printf 'SPACED = value-with-space   # remove me\n'
  printf 'export TM_TOKEN = "tm_old_literal#secret"\n'
} > "$config"

assert_eq "https://example.test///" "$(read_existing_config_value TM_BASE_URL "$config")" "reads unquoted TM_BASE_URL and strips inline comment"
assert_eq "https://quoted.example/#keep" "$(read_existing_config_value QUOTED_BASE_URL "$config")" "reads export double-quoted value with # preserved"
assert_eq "https://single.example/#keep" "$(read_existing_config_value SINGLE_BASE_URL "$config")" "reads single-quoted value with # preserved"
assert_eq "value-with-space" "$(read_existing_config_value SPACED "$config")" "reads whitespace around equals"
assert_eq "tm_old_literal#secret" "$(read_existing_config_value TM_TOKEN "$config")" "detects old literal TM_TOKEN"
assert_eq "https://example.test" "$(strip_trailing_slashes "$(read_existing_config_value TM_BASE_URL "$config")")" "normalizes trailing slashes"

fake_bin="$TMP_DIR/bin"
mkdir -p "$fake_bin"
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "$1" in\n'
  printf '  find-generic-password) printf "tm_stored_token\\n" ;;\n'
  printf '  add-generic-password) exit 0 ;;\n'
  printf '  *) exit 1 ;;\n'
  printf 'esac\n'
} > "$fake_bin/security"
chmod +x "$fake_bin/security"

original_path="$PATH"
PATH="$fake_bin:$PATH"
PLATFORM="macos"
CONFIG_FILE="$config"

printf 'export TM_TOKEN="$(security find-generic-password -s "$TM_CREDENTIAL_SERVICE" -a "$TM_CREDENTIAL_ACCOUNT" -w 2>/dev/null || true)"\n' > "$config"
TM_INSTALL_PROMPT_TOKEN=""
assert_eq "tm_stored_token" "$(resolve_token "https://example.test")" "blank prompt input reuses stored credential"

TM_INSTALL_PROMPT_TOKEN="tm_replacement_token"
assert_eq "tm_replacement_token" "$(resolve_token "https://example.test")" "prompt input replaces stored credential"
unset TM_INSTALL_PROMPT_TOKEN

TM_INSTALL_TTY_PATH="$TMP_DIR/missing-tty"
if output="$(prompt_new_or_existing_token "tm_stored_token" 2>&1)"; then
  printf 'not ok - stored credential without tty should fail\nunexpected: %s\n' "$output" >&2
  exit 1
fi
assert_text_contains "unavailable to confirm whether to reuse or replace it" "$output" "stored credential without tty fails clearly"
TM_INSTALL_TTY_PATH="/dev/tty"

printf 'export TM_TOKEN=tm_plaintext_token\n' > "$config"
assert_eq "tm_plaintext_token" "$(resolve_token "https://example.test")" "plaintext token overrides stored credential for migration"
PATH="$original_path"

{
  printf 'TM_TOKEN=tm_plain # comment\n'
  printf 'export TM_TOKEN = tm_export\n'
  printf ' TM_TOKEN = "tm_double#secret"\n'
  printf "export TM_TOKEN='tm_single#secret'\n"
  printf 'OTHER=tm_not_secret\n'
} > "$config"

redact_config_content "$config" > "$redacted"
assert_not_contains "tm_plain" "$redacted" "redacts unquoted token"
assert_not_contains "tm_export" "$redacted" "redacts export token"
assert_not_contains "tm_double#secret" "$redacted" "redacts double-quoted token"
assert_not_contains "tm_single#secret" "$redacted" "redacts single-quoted token"
assert_contains 'OTHER=tm_not_secret' "$redacted" "keeps non-token assignments"

CONFIG_FILE="$TMP_DIR/tm-config"
PLATFORM="macos"
TM_CREDENTIAL_TARGET_VALUE="TestManagement API Token"
write_config "$CONFIG_FILE" "https://mac.example" >/dev/null
assert_contains 'security find-generic-password' "$CONFIG_FILE" "macOS config uses security lookup"
assert_contains '2>/dev/null || true' "$CONFIG_FILE" "macOS config suppresses lookup failures"
assert_not_contains 'tm_old_literal' "$CONFIG_FILE" "macOS config contains no literal token"
bash -n "$CONFIG_FILE"
assert_eq "0" "$?" "macOS generated config is bash-compatible"
assert_eq '$(security find-generic-password -s ' "$(read_existing_config_value TM_TOKEN "$CONFIG_FILE")" "parser reads generated lookup as nonliteral"

PLATFORM="windows-git-bash"
TM_CREDENTIAL_TARGET_VALUE="TestManagement API Token:https://win.example"
write_config "$CONFIG_FILE" "https://win.example" >/dev/null
assert_contains 'powershell.exe -NoProfile -NonInteractive' "$CONFIG_FILE" "Windows config uses PowerShell lookup"
assert_contains '2>/dev/null || true' "$CONFIG_FILE" "Windows config suppresses lookup failures"
assert_contains 'TM_CREDENTIAL_TARGET="$TM_CREDENTIAL_TARGET"' "$CONFIG_FILE" "Windows config passes target via environment"
assert_not_contains 'tm_old_literal' "$CONFIG_FILE" "Windows config contains no literal token"
bash -n "$CONFIG_FILE"
assert_eq "0" "$?" "Windows generated config is bash-compatible"

# --- SemVer comparison (matching semver.org's canonical precedence chain) --

assert_eq "0" "$(semver_compare 1.0.0 1.0.0)" "semver_compare: equal versions"
assert_eq "-1" "$(semver_compare 1.0.0 2.0.0)" "semver_compare: lower major"
assert_eq "1" "$(semver_compare 2.1.1 2.1.0)" "semver_compare: higher patch"
assert_eq "0" "$(semver_compare 1.0.0+build1 1.0.0+build2)" "semver_compare: build metadata never affects precedence"
assert_eq "-1" "$(semver_compare 1.0.0-alpha 1.0.0)" "semver_compare: a prerelease is lower than the same release"

# 1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < 1.0.0-beta.2
#   < 1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0
chain=(1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta 1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0)
chain_len=${#chain[@]}
for ((i = 0; i < chain_len - 1; i++)); do
  assert_eq "-1" "$(semver_compare "${chain[$i]}" "${chain[$((i + 1))]}")" \
    "semver_compare: ${chain[$i]} < ${chain[$((i + 1))]} (SemVer spec chain)"
done

assert_eq "0" "$(is_stable_semver 1.2.3; echo $?)" "is_stable_semver accepts a plain X.Y.Z"
assert_eq "1" "$(is_stable_semver 1.2.3-rc.1; echo $?)" "is_stable_semver rejects a prerelease"

# --- Deployment URL validation/canonicalization -----------------------------

assert_eq "0" "$(validate_deployment_url https://example.com; echo $?)" "validate_deployment_url accepts https"
assert_eq "0" "$(validate_deployment_url http://localhost:3000; echo $?)" "validate_deployment_url accepts loopback http"
assert_eq "1" "$(validate_deployment_url http://evil.example.com; echo $?)" "validate_deployment_url rejects non-loopback http"
assert_eq "1" "$(validate_deployment_url https://user@example.com; echo $?)" "validate_deployment_url rejects userinfo"
assert_eq "1" "$(validate_deployment_url 'https://example.com/a?x=1'; echo $?)" "validate_deployment_url rejects a query string"
assert_eq "https://example.com" "$(canonicalize_deployment_url 'HTTPS://Example.COM:443/')" "canonicalize_deployment_url lowercases and strips the default port/trailing slash"

# --- Immutable artifact URL check -------------------------------------------

assert_eq "0" "$(is_immutable_https_url https://github.com/x/y/releases/download/v1/a.tar.gz; echo $?)" "is_immutable_https_url accepts a pinned release asset URL"
assert_eq "1" "$(is_immutable_https_url https://github.com/x/y/releases/download/main/a.tar.gz; echo $?)" "is_immutable_https_url rejects a /main/ URL"
assert_eq "1" "$(is_immutable_https_url http://github.com/x/y/releases/download/v1/a.tar.gz; echo $?)" "is_immutable_https_url rejects a plain http URL"

# --- Installation UUID format ------------------------------------------------

uuid="$(generate_uuid)"
if [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
  pass_count=$((pass_count + 1))
  printf 'ok - generate_uuid produces a lowercase RFC4122 v4 UUID\n'
else
  printf 'not ok - generate_uuid produces a lowercase RFC4122 v4 UUID\nactual: %s\n' "$uuid" >&2
  exit 1
fi

printf '1..%d\n' "$pass_count"
