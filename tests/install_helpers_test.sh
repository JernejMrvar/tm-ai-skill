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
assert_eq "tm_stored_token" "$(resolve_token "https://example.test")" "rerun uses stored credential when config has lookup"

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
write_config "$CONFIG_FILE" "https://mac.example" "ask" >/dev/null
assert_contains 'security find-generic-password' "$CONFIG_FILE" "macOS config uses security lookup"
assert_contains '2>/dev/null || true' "$CONFIG_FILE" "macOS config suppresses lookup failures"
assert_not_contains 'tm_old_literal' "$CONFIG_FILE" "macOS config contains no literal token"
bash -n "$CONFIG_FILE"
assert_eq "0" "$?" "macOS generated config is bash-compatible"
assert_eq '$(security find-generic-password -s ' "$(read_existing_config_value TM_TOKEN "$CONFIG_FILE")" "parser reads generated lookup as nonliteral"

PLATFORM="windows-git-bash"
TM_CREDENTIAL_TARGET_VALUE="TestManagement API Token:https://win.example"
write_config "$CONFIG_FILE" "https://win.example" "mandatory" >/dev/null
assert_contains 'powershell.exe -NoProfile -NonInteractive' "$CONFIG_FILE" "Windows config uses PowerShell lookup"
assert_contains '2>/dev/null || true' "$CONFIG_FILE" "Windows config suppresses lookup failures"
assert_contains 'TM_CREDENTIAL_TARGET="$TM_CREDENTIAL_TARGET"' "$CONFIG_FILE" "Windows config passes target via environment"
assert_not_contains 'tm_old_literal' "$CONFIG_FILE" "Windows config contains no literal token"
bash -n "$CONFIG_FILE"
assert_eq "0" "$?" "Windows generated config is bash-compatible"

printf '1..%d\n' "$pass_count"
