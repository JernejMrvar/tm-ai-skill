#!/usr/bin/env bash
set -euo pipefail

# Legacy fallback source, used only when a deployment has no promoted,
# compatible release yet (see sync_targets_legacy). The versioned flow
# (sync_targets_release) never uses this — it only ever installs pinned,
# checksum-verified release artifacts.
SKILL_URL="https://raw.githubusercontent.com/JernejMrvar/tm-ai-skill/main/SKILL.md"
DEFAULT_TM_BASE_URL="https://test-management-project.vercel.app"
CONFIG_FILE="${TM_CONFIG_FILE:-$HOME/.tm-config}"
CONFIG_BACKUP_TIMESTAMP="${CONFIG_BACKUP_TIMESTAMP:-}"
TM_INSTALL_TEST_MODE="${TM_INSTALL_TEST_MODE:-0}"
TM_INSTALL_TTY_PATH="${TM_INSTALL_TTY_PATH:-/dev/tty}"
TM_STATE_DIR="${TM_STATE_DIR:-$HOME/.tm}"

TM_INSTALLER_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
TM_INSTALLER_VERSION="0.0.0-dev"
if [ -n "$TM_INSTALLER_SELF_DIR" ] && [ -f "$TM_INSTALLER_SELF_DIR/VERSION" ]; then
  TM_INSTALLER_VERSION="$(cat "$TM_INSTALLER_SELF_DIR/VERSION" 2>/dev/null || echo "0.0.0-dev")"
fi

# Contract versions this installer implements. A promoted release that
# requires more than this (an incompatible reportContractVersion/
# manifestContractVersion, or a higher tmApiContractVersion) is never used,
# regardless of its SemVer precedence.
SUPPORTED_REPORT_CONTRACT_VERSION=1
SUPPORTED_MANIFEST_CONTRACT_VERSION=1
SUPPORTED_TM_API_CONTRACT_VERSION=1

PLATFORM=""
TM_SECRET_BACKEND_VALUE=""
TM_CREDENTIAL_TARGET_VALUE=""

MODE="install"
OPT_BASE_URL=""
OPT_DISPLAY_NAME=""
OPT_SWITCH_ACCOUNT=0
OPT_TARGETS=""
OPT_YES=0

CRED_KIND=""
CRED_OWNER_ID=""
CRED_OWNER_NAME=""
CRED_GENERATION=""
CRED_PROJECT_ID=""
CRED_USER_ID=""
CRED_TOKEN_NAME=""

VERIFY_RESULT=""
VERIFY_FAILURE_CODE=""
VERIFY_GENERATION=""

RELEASE_JSON=""
RELEASE_PRESENT=0
RELEASE_COMPATIBLE=0
RELEASE_INSTALLER_VERSION=""
RELEASE_TARGET_VERSION=""
RELEASE_TARGET_URL=""
RELEASE_TARGET_SHA256=""
RELEASE_TARGET_SIZE=""

TARGET_RESULTS_FILE=""
LAST_WRITE_FAILURE_CODE="UNKNOWN_ERROR"
REPORT_HTTP_CODE=""
REPORT_RESPONSE_BODY=""
REPORT_DELIVERED=0
STATE_LOCK_HELD=""
INSTALLATION_ID=""

# ---------------------------------------------------------------------------
# Generic string helpers (unchanged from the pre-POV-31 installer, kept for
# backward compatibility with existing tests and behavior).
# ---------------------------------------------------------------------------

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

strip_trailing_slashes() {
  local value="$1"
  while [ "${#value}" -gt 1 ] && [ "${value%/}" != "$value" ]; do
    value="${value%/}"
  done
  printf '%s' "$value"
}

lower() {
  tr '[:upper:]' '[:lower:]'
}

print_usage() {
  cat <<'EOF'
Usage: install.sh [MODE] [OPTIONS]

Modes:
  install         Configure a credential and install/update the skill (default).
  reconfigure     Explicitly replace the stored credential, then sync files.
  update          Sync files against the promoted release. Never touches credentials.
  check           Report current local state without changing files or credentials.
  retry-report    Resend a previously undelivered installation report.

Options:
  --base-url=URL       Override the configured TestManagement deployment URL.
  --display-name=NAME  Human-readable label for this installation (e.g. "My laptop").
  --switch-account     Required to replace a stored credential for a different account.
  --target=LIST        Comma-separated subset of: codex,claude,cursor (default: all three).
  --yes                Skip non-essential interactive confirmations.
  -h, --help           Show this help.

The API token is never accepted as a command-line argument. Pipe it on stdin
for non-interactive use, or run interactively for a secure /dev/tty prompt.
EOF
}

# ---------------------------------------------------------------------------
# Platform detection (unchanged).
# ---------------------------------------------------------------------------

detect_platform() {
  local uname_s
  uname_s="$(uname -s 2>/dev/null || true)"

  case "$uname_s" in
    Darwin)
      PLATFORM="macos"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      PLATFORM="windows-git-bash"
      ;;
    Linux)
      if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        PLATFORM="unsupported-wsl"
      else
        PLATFORM="unsupported-linux"
      fi
      ;;
    *)
      PLATFORM="unsupported"
      ;;
  esac

  printf '%s\n' "$PLATFORM"
}

ensure_supported_platform() {
  case "$PLATFORM" in
    macos)
      if ! command -v security >/dev/null 2>&1; then
        echo "Error: macOS credential storage requires the 'security' command, but it was not found." >&2
        exit 2
      fi
      ;;
    windows-git-bash)
      if ! command -v powershell.exe >/dev/null 2>&1; then
        echo "Error: Windows Git Bash credential storage requires powershell.exe, but it was not found." >&2
        exit 2
      fi
      ;;
    unsupported-linux)
      echo "Error: Linux is not supported by this installer yet. No files were changed." >&2
      exit 2
      ;;
    unsupported-wsl)
      echo "Error: WSL is not supported by this installer. Run it from macOS or Windows Git Bash. No files were changed." >&2
      exit 2
      ;;
    *)
      echo "Error: unsupported platform for this installer. No files were changed." >&2
      exit 2
      ;;
  esac
}

ensure_dependencies() {
  local missing=()
  local cmd
  for cmd in curl jq tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    missing+=("shasum-or-sha256sum")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Error: missing required dependencies: ${missing[*]}" >&2
    echo "Install them and re-run:" >&2
    echo "  macOS:            brew install jq   (curl, tar, and shasum already ship with macOS)" >&2
    echo "  Windows Git Bash: pacman -S mingw-w64-x86_64-jq   (curl, tar, sha256sum ship with Git for Windows)" >&2
    exit 2
  fi
}

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    return 1
  fi
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Deployment URL validation/canonicalization.
# ---------------------------------------------------------------------------

is_immutable_https_url() {
  local url="$1" lowered
  lowered="$(printf '%s' "$url" | lower)"
  case "$lowered" in
    https://*) : ;;
    *) return 1 ;;
  esac
  case "$lowered" in
    */latest/*|*/latest|*/main/*|*/main|*/master/*|*/master|*/head/*|*/head|*/trunk/*|*/trunk) return 1 ;;
  esac
  return 0
}

# HTTPS in normal use; explicitly supported loopback HTTP for local dev.
# Rejects userinfo, query, fragment, and control characters.
validate_deployment_url() {
  local url="$1"
  if [[ "$url" =~ [[:cntrl:]] ]]; then
    return 1
  fi
  if ! [[ "$url" =~ ^https?://[^/?#[:space:]]+(/[^?#[:space:]]*)?$ ]]; then
    return 1
  fi
  local authority
  authority="${url#*://}"
  authority="${authority%%/*}"
  case "$authority" in
    *@*) return 1 ;;
  esac
  case "$url" in
    http://*)
      case "$authority" in
        localhost|localhost:*|127.0.0.1|127.0.0.1:*) : ;;
        *) return 1 ;;
      esac
      ;;
  esac
  return 0
}

# Canonicalizes trailing slash/host case/default port so the same logical
# deployment always hashes to the same credential/installation identity.
canonicalize_deployment_url() {
  local url scheme host_and_rest host rest
  url="$(strip_trailing_slashes "$1")"
  scheme="${url%%://*}"
  host_and_rest="${url#*://}"
  case "$host_and_rest" in
    */*) host="${host_and_rest%%/*}"; rest="/${host_and_rest#*/}" ;;
    *) host="$host_and_rest"; rest="" ;;
  esac
  scheme="$(printf '%s' "$scheme" | lower)"
  host="$(printf '%s' "$host" | lower)"
  case "$scheme" in
    https) host="${host%:443}" ;;
    http) host="${host%:80}" ;;
  esac
  rest="$(strip_trailing_slashes "${rest:-/}")"
  if [ "$rest" = "/" ]; then rest=""; fi
  printf '%s://%s%s' "$scheme" "$host" "$rest"
}

# ---------------------------------------------------------------------------
# SemVer helpers (major.minor.patch[-prerelease][+build]). Build metadata is
# parsed but never affects precedence, matching POV-30's `compareSkillVersion`.
# ---------------------------------------------------------------------------

SV_MAJOR=0
SV_MINOR=0
SV_PATCH=0
SV_PRERELEASE=""

semver_is_valid() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]
}

is_stable_semver() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

semver_split() {
  local v="$1" core pre
  v="${v%%+*}"
  core="${v%%-*}"
  pre=""
  case "$v" in
    *-*) pre="${v#*-}" ;;
  esac
  IFS='.' read -r SV_MAJOR SV_MINOR SV_PATCH <<< "$core"
  SV_PRERELEASE="$pre"
}

# Echoes -1, 0, or 1 comparing SemVer string $1 to $2, per semver.org
# precedence rules (numeric identifiers compare numerically, alphanumeric
# identifiers compare lexically (ASCII), a version without a prerelease
# outranks one with a prerelease at the same major.minor.patch).
semver_compare() {
  local a_major a_minor a_patch a_pre b_major b_minor b_patch b_pre

  semver_split "$1"
  a_major="$SV_MAJOR"; a_minor="$SV_MINOR"; a_patch="$SV_PATCH"; a_pre="$SV_PRERELEASE"
  semver_split "$2"
  b_major="$SV_MAJOR"; b_minor="$SV_MINOR"; b_patch="$SV_PATCH"; b_pre="$SV_PRERELEASE"

  if [ "$a_major" -ne "$b_major" ]; then
    [ "$a_major" -gt "$b_major" ] && { echo 1; return; } || { echo -1; return; }
  fi
  if [ "$a_minor" -ne "$b_minor" ]; then
    [ "$a_minor" -gt "$b_minor" ] && { echo 1; return; } || { echo -1; return; }
  fi
  if [ "$a_patch" -ne "$b_patch" ]; then
    [ "$a_patch" -gt "$b_patch" ] && { echo 1; return; } || { echo -1; return; }
  fi

  if [ -z "$a_pre" ] && [ -z "$b_pre" ]; then echo 0; return; fi
  if [ -z "$a_pre" ]; then echo 1; return; fi
  if [ -z "$b_pre" ]; then echo -1; return; fi

  local a_ids=() b_ids=()
  IFS='.' read -r -a a_ids <<< "$a_pre"
  IFS='.' read -r -a b_ids <<< "$b_pre"
  local i=0 a_len=${#a_ids[@]} b_len=${#b_ids[@]}
  while [ "$i" -lt "$a_len" ] && [ "$i" -lt "$b_len" ]; do
    local ai="${a_ids[$i]}" bi="${b_ids[$i]}"
    if [[ "$ai" =~ ^[0-9]+$ ]] && [[ "$bi" =~ ^[0-9]+$ ]]; then
      if [ "$ai" -ne "$bi" ]; then
        [ "$ai" -gt "$bi" ] && { echo 1; return; } || { echo -1; return; }
      fi
    elif [[ "$ai" =~ ^[0-9]+$ ]]; then
      echo -1; return
    elif [[ "$bi" =~ ^[0-9]+$ ]]; then
      echo 1; return
    else
      if [ "$ai" != "$bi" ]; then
        if [[ "$ai" < "$bi" ]]; then echo -1; else echo 1; fi
        return
      fi
    fi
    i=$((i + 1))
  done
  if [ "$a_len" -ne "$b_len" ]; then
    [ "$a_len" -gt "$b_len" ] && { echo 1; return; } || { echo -1; return; }
  fi
  echo 0
}

# Mirrors compareSkillVersion(): up_to_date / update_available / ahead /
# unknown. ("no_release" is decided by the caller before this is reached.)
compare_installed_version() {
  local installed="$1" release="$2" cmp
  if [ -z "$installed" ] || ! semver_is_valid "$installed"; then
    echo "unknown"
    return
  fi
  cmp="$(semver_compare "$installed" "$release")"
  case "$cmp" in
    0) echo "up_to_date" ;;
    -1) echo "update_available" ;;
    1) echo "ahead" ;;
  esac
}

# ---------------------------------------------------------------------------
# ~/.tm-config parsing and credential storage (unchanged behavior/tests).
# ---------------------------------------------------------------------------

read_existing_config_value() {
  local name="$1"
  local file="${2:-$CONFIG_FILE}"
  local line rest value char i len escaped

  [ -f "$file" ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      ""|\#*) continue ;;
    esac

    if [[ "$line" =~ ^(export[[:space:]]+)?$name[[:space:]]*=(.*)$ ]]; then
      rest="${BASH_REMATCH[2]}"
      rest="$(trim "$rest")"

      case "$rest" in
        \"*)
          value=""
          escaped=0
          rest="${rest#\"}"
          len="${#rest}"
          for ((i = 0; i < len; i++)); do
            char="${rest:i:1}"
            if [ "$escaped" -eq 1 ]; then
              value+="$char"
              escaped=0
            elif [ "$char" = "\\" ]; then
              escaped=1
            elif [ "$char" = '"' ]; then
              printf '%s\n' "$value"
              return 0
            else
              value+="$char"
            fi
          done
          printf '%s\n' "$value"
          return 0
          ;;
        \'*)
          rest="${rest#\'}"
          value="${rest%%\'*}"
          printf '%s\n' "$value"
          return 0
          ;;
        *)
          value="${rest%%#*}"
          value="$(trim "$value")"
          printf '%s\n' "$value"
          return 0
          ;;
      esac
    fi
  done < "$file"

  return 1
}

credential_target() {
  local base_url="$1"

  case "$PLATFORM" in
    macos)
      TM_SECRET_BACKEND_VALUE="macos-keychain"
      TM_CREDENTIAL_TARGET_VALUE="TestManagement API Token"
      ;;
    windows-git-bash)
      TM_SECRET_BACKEND_VALUE="windows-credential-manager"
      TM_CREDENTIAL_TARGET_VALUE="TestManagement API Token:$base_url"
      ;;
  esac

  printf '%s\n' "$TM_CREDENTIAL_TARGET_VALUE"
}

macos_credential_exists() {
  local base_url="$1"
  security find-generic-password -s "TestManagement API Token" -a "$base_url" -w >/dev/null 2>&1
}

windows_powershell_credential_script() {
  cat <<'EOF'
$ErrorActionPreference = "Stop"
$signature = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CredMan {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct CREDENTIAL {
    public UInt32 Flags;
    public UInt32 Type;
    public string TargetName;
    public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public UInt32 CredentialBlobSize;
    public IntPtr CredentialBlob;
    public UInt32 Persist;
    public UInt32 AttributeCount;
    public IntPtr Attributes;
    public string TargetAlias;
    public string UserName;
  }

  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool CredRead(string target, UInt32 type, UInt32 reservedFlag, out IntPtr credentialPtr);

  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool CredWrite(ref CREDENTIAL credential, UInt32 flags);

  [DllImport("advapi32.dll", SetLastError = true)]
  public static extern void CredFree(IntPtr buffer);
}
"@
Add-Type -TypeDefinition $signature

function Read-TmCredential([string]$target) {
  [IntPtr]$ptr = [IntPtr]::Zero
  if (-not [CredMan]::CredRead($target, 1, 0, [ref]$ptr)) {
    exit 1
  }
  try {
    $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][CredMan+CREDENTIAL])
    if ($cred.CredentialBlobSize -eq 0) {
      return
    }
    $bytes = New-Object byte[] $cred.CredentialBlobSize
    [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $bytes.Length)
    [Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0)
  } finally {
    [CredMan]::CredFree($ptr)
  }
}

function Write-TmCredential([string]$target, [string]$secret) {
  $bytes = [Text.Encoding]::Unicode.GetBytes($secret)
  $blob = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
  try {
    [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $blob, $bytes.Length)
    $cred = New-Object CredMan+CREDENTIAL
    $cred.Type = 1
    $cred.TargetName = $target
    $cred.CredentialBlobSize = $bytes.Length
    $cred.CredentialBlob = $blob
    $cred.Persist = 2
    $cred.UserName = "TM_TOKEN"
    if (-not [CredMan]::CredWrite([ref]$cred, 0)) {
      throw "CredWrite failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
  } finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($blob)
  }
}

if ($env:TM_CREDENTIAL_ACTION -eq "write") {
  Write-TmCredential $env:TM_CREDENTIAL_TARGET $env:TM_TOKEN_TO_STORE
} else {
  Read-TmCredential $env:TM_CREDENTIAL_TARGET
}
EOF
}

windows_credential_read() {
  TM_CREDENTIAL_ACTION="read" TM_CREDENTIAL_TARGET="$1" \
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(windows_powershell_credential_script)" 2>/dev/null
}

windows_credential_write() {
  TM_CREDENTIAL_ACTION="write" TM_CREDENTIAL_TARGET="$1" TM_TOKEN_TO_STORE="$2" \
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(windows_powershell_credential_script)"
}

credential_exists() {
  local base_url="$1"
  local target
  target="$(credential_target "$base_url")"

  case "$PLATFORM" in
    macos)
      macos_credential_exists "$base_url"
      ;;
    windows-git-bash)
      windows_credential_read "$target" >/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

prompt_token() {
  local prompt="${1:-Paste your TestManagement API token (starts with tm_ or tmp_): }"
  local allow_empty="${2:-0}"
  local existing_token="${3:-}"
  local token=""

  if [ "$TM_INSTALL_TEST_MODE" = "1" ] && [ "${TM_INSTALL_PROMPT_TOKEN+x}" = "x" ]; then
    token="$TM_INSTALL_PROMPT_TOKEN"
  elif ! { printf '%s' "$prompt" > "$TM_INSTALL_TTY_PATH" && IFS= read -rs token < "$TM_INSTALL_TTY_PATH" && printf '\n' > "$TM_INSTALL_TTY_PATH"; } 2>/dev/null; then
    if [ "$allow_empty" = "1" ] && [ -n "$existing_token" ]; then
      echo "Error: TM_TOKEN is already stored, but /dev/tty is unavailable to confirm whether to reuse or replace it." >&2
      echo "Run the installer from an interactive terminal, then press Enter to reuse it or paste a new token." >&2
      return 1
    fi
    echo "Error: no stored token was found and /dev/tty is unavailable for a secure prompt." >&2
    echo "Run the installer from an interactive terminal, pipe a token on stdin, or migrate an existing TM_TOKEN in ~/.tm-config." >&2
    return 1
  fi

  if [ -z "$token" ] && [ "$allow_empty" = "1" ] && [ -n "$existing_token" ]; then
    printf '%s\n' "$existing_token"
    return 0
  fi

  if [[ "$token" != tm_* ]] && [[ "$token" != tmp_* ]]; then
    echo "Error: token must start with tm_ or tmp_." >&2
    return 1
  fi

  printf '%s\n' "$token"
}

prompt_new_or_existing_token() {
  local existing_token="$1"

  prompt_token "A token is already stored. Paste a new token to replace it, or press Enter to reuse it: " "1" "$existing_token"
}

prompt_required_token() {
  prompt_token
}

store_secret() {
  local base_url="$1"
  local token="$2"
  local target
  target="$(credential_target "$base_url")"

  case "$PLATFORM" in
    macos)
      security add-generic-password -U -s "TestManagement API Token" -a "$base_url" -w "$token" >/dev/null
      ;;
    windows-git-bash)
      windows_credential_write "$target" "$token" >/dev/null
      ;;
    *)
      echo "Error: unsupported platform for credential storage." >&2
      return 1
      ;;
  esac
}

redact_config_content() {
  local file="$1"
  local line leading export_part

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([[:space:]]*)((export[[:space:]]+)?)TM_TOKEN[[:space:]]*= ]]; then
      leading="${BASH_REMATCH[1]}"
      export_part="${BASH_REMATCH[2]}"
      printf '%s%sTM_TOKEN="[redacted]"\n' "$leading" "$export_part"
    else
      printf '%s\n' "$line"
    fi
  done < "$file"
}

backup_existing_config() {
  local file="${1:-$CONFIG_FILE}"
  local timestamp backup

  [ -f "$file" ] || return 0

  timestamp="${CONFIG_BACKUP_TIMESTAMP:-$(date +%Y%m%d%H%M%S)}"
  backup="${file}.backup.${timestamp}"
  redact_config_content "$file" > "$backup"
  chmod 600 "$backup" 2>/dev/null || true
  echo "✓ Backed up existing config to $backup with TM_TOKEN redacted"
}

write_config() {
  local file="${1:-$CONFIG_FILE}"
  local base_url="$2"
  local target="$TM_CREDENTIAL_TARGET_VALUE"

  case "$PLATFORM" in
    macos)
      cat > "$file" <<EOF
export TM_BASE_URL="$base_url"
export TM_SECRET_BACKEND="macos-keychain"
export TM_CREDENTIAL_SERVICE="TestManagement API Token"
export TM_CREDENTIAL_ACCOUNT="\$TM_BASE_URL"
export TM_TOKEN="\$(security find-generic-password -s "\$TM_CREDENTIAL_SERVICE" -a "\$TM_CREDENTIAL_ACCOUNT" -w 2>/dev/null || true)"
EOF
      ;;
    windows-git-bash)
      cat > "$file" <<EOF
export TM_BASE_URL="$base_url"
export TM_SECRET_BACKEND="windows-credential-manager"
export TM_CREDENTIAL_TARGET="$target"
export TM_TOKEN="\$(TM_CREDENTIAL_TARGET="\$TM_CREDENTIAL_TARGET" powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command '\$ErrorActionPreference = "Stop"; Add-Type -TypeDefinition "using System; using System.Runtime.InteropServices; using System.Text; public static class CredMan { [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct CREDENTIAL { public UInt32 Flags; public UInt32 Type; public string TargetName; public string Comment; public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten; public UInt32 CredentialBlobSize; public IntPtr CredentialBlob; public UInt32 Persist; public UInt32 AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName; } [DllImport(""advapi32.dll"", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool CredRead(string target, UInt32 type, UInt32 reservedFlag, out IntPtr credentialPtr); [DllImport(""advapi32.dll"", SetLastError = true)] public static extern void CredFree(IntPtr buffer); }"; [IntPtr]\$ptr = [IntPtr]::Zero; if (-not [CredMan]::CredRead(\$env:TM_CREDENTIAL_TARGET, 1, 0, [ref]\$ptr)) { exit 1 }; try { \$cred = [Runtime.InteropServices.Marshal]::PtrToStructure(\$ptr, [type][CredMan+CREDENTIAL]); if (\$cred.CredentialBlobSize -gt 0) { \$bytes = New-Object byte[] \$cred.CredentialBlobSize; [Runtime.InteropServices.Marshal]::Copy(\$cred.CredentialBlob, \$bytes, 0, \$bytes.Length); [Text.Encoding]::Unicode.GetString(\$bytes).TrimEnd([char]0) } } finally { [CredMan]::CredFree(\$ptr) }' 2>/dev/null || true)"
EOF
      ;;
  esac

  chmod 600 "$file" 2>/dev/null || true
  echo "✓ Wrote $file with credential lookup logic"
}

resolve_base_url() {
  local value
  value="$(read_existing_config_value TM_BASE_URL "$CONFIG_FILE" 2>/dev/null || true)"
  value="${value:-$DEFAULT_TM_BASE_URL}"
  strip_trailing_slashes "$value"
}

resolve_base_url_opt() {
  if [ -n "$OPT_BASE_URL" ]; then
    strip_trailing_slashes "$OPT_BASE_URL"
  else
    resolve_base_url
  fi
}

resolve_token() {
  local base_url="$1"
  local existing_token stored_token target

  existing_token="$(read_existing_config_value TM_TOKEN "$CONFIG_FILE" 2>/dev/null || true)"
  if [[ "$existing_token" == tm_* ]] || [[ "$existing_token" == tmp_* ]]; then
    printf '%s\n' "$existing_token"
    return 0
  fi

  if credential_exists "$base_url"; then
    target="$(credential_target "$base_url")"
    case "$PLATFORM" in
      macos)
        stored_token="$(security find-generic-password -s "TestManagement API Token" -a "$base_url" -w 2>/dev/null || true)"
        ;;
      windows-git-bash)
        stored_token="$(windows_credential_read "$target" 2>/dev/null || true)"
        ;;
    esac
    if [[ "$stored_token" == tm_* ]] || [[ "$stored_token" == tmp_* ]]; then
      prompt_new_or_existing_token "$stored_token"
      return
    elif [ -n "$stored_token" ]; then
      echo "Warning: stored credential does not start with tm_ or tmp_; prompting for a replacement." >&2
    fi
  fi

  prompt_required_token
}

read_config_token_no_prompt() {
  local base_url="$1"
  local existing_token
  existing_token="$(read_existing_config_value TM_TOKEN "$CONFIG_FILE" 2>/dev/null || true)"
  if [[ "$existing_token" == tm_* ]] || [[ "$existing_token" == tmp_* ]]; then
    printf '%s\n' "$existing_token"
    return 0
  fi
  (
    set +e
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null
    printf '%s' "${TM_TOKEN:-}"
  )
}

acquire_candidate_token() {
  local base_url="$1"
  if [ "${TM_INSTALL_PROMPT_TOKEN+x}" != "x" ] && [ ! -t 0 ]; then
    local token
    IFS= read -r token || true
    if [[ "$token" != tm_* ]] && [[ "$token" != tmp_* ]]; then
      echo "Error: token read from stdin must start with tm_ or tmp_." >&2
      return 1
    fi
    printf '%s\n' "$token"
    return 0
  fi
  resolve_token "$base_url"
}

validate_connection() {
  local file="${1:-$CONFIG_FILE}"

  (
    set +e
    # shellcheck disable=SC1090
    source "$file" 2>/dev/null
    if [ -z "${TM_TOKEN:-}" ]; then
      exit 1
    fi
    curl -fsS -H "Authorization: Bearer $TM_TOKEN" "$TM_BASE_URL/api/v1/folders" >/dev/null
  )
}

# ---------------------------------------------------------------------------
# Credential kind detection (POV-28 /me contract) and identity tracking.
# ---------------------------------------------------------------------------

call_me() {
  local base_url="$1" token="$2"
  curl -fsS --max-time 15 -H "Authorization: Bearer $token" "$base_url/api/v1/me" 2>/dev/null
}

call_projects_discovery() {
  local base_url="$1" token="$2"
  curl -fsS --max-time 15 -H "Authorization: Bearer $token" "$base_url/api/v1/projects" 2>/dev/null
}

# Sets CRED_KIND (legacy|personal) plus its identity fields from a validated
# /api/v1/me response. Never trusts a tm_/tmp_ prefix alone. For personal
# keys, also confirms /api/v1/projects is reachable without a project header
# (an empty or Guest/read-only discovery result is a valid, successful check).
validate_candidate_credential() {
  local base_url="$1" token="$2"
  local me_json kind

  me_json="$(call_me "$base_url" "$token")" || return 1
  kind="$(printf '%s' "$me_json" | jq -r '.kind // empty' 2>/dev/null)"

  case "$kind" in
    legacy)
      CRED_KIND="legacy"
      CRED_PROJECT_ID="$(printf '%s' "$me_json" | jq -r '.projectId')"
      CRED_USER_ID="$(printf '%s' "$me_json" | jq -r '.userId')"
      CRED_TOKEN_NAME="$(printf '%s' "$me_json" | jq -r '.tokenName')"
      ;;
    personal)
      CRED_KIND="personal"
      CRED_OWNER_ID="$(printf '%s' "$me_json" | jq -r '.ownerId')"
      CRED_OWNER_NAME="$(printf '%s' "$me_json" | jq -r '.ownerName // empty')"
      CRED_GENERATION="$(printf '%s' "$me_json" | jq -r '.generation')"
      call_projects_discovery "$base_url" "$token" >/dev/null || return 1
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

candidate_identity_string() {
  if [ "$CRED_KIND" = "legacy" ]; then
    printf 'legacy:%s:%s' "$CRED_PROJECT_ID" "$CRED_USER_ID"
  else
    printf 'personal:%s' "$CRED_OWNER_ID"
  fi
}

existing_identity_for_deployment() {
  local base_url="$1" f
  f="$(local_version_state_dir "$base_url")/last_identity"
  [ -f "$f" ] && cat "$f" 2>/dev/null || true
}

record_identity_for_deployment() {
  local base_url="$1" identity="$2" dir
  dir="$(local_version_state_dir "$base_url")"
  mkdir -p "$dir" 2>/dev/null || true
  chmod 700 "$dir" 2>/dev/null || true
  printf '%s' "$identity" > "$dir/last_identity"
  chmod 600 "$dir/last_identity" 2>/dev/null || true
}

confirm_account_switch_interactive() {
  local answer
  if [ "$TM_INSTALL_TEST_MODE" = "1" ]; then
    [ "${TM_INSTALL_CONFIRM_SWITCH:-0}" = "1" ]
    return
  fi
  { printf 'A different account is already configured for this deployment. Switch to the new one? [y/N]: ' > "$TM_INSTALL_TTY_PATH" && IFS= read -r answer < "$TM_INSTALL_TTY_PATH"; } 2>/dev/null || return 1
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Fresh-process credential read-back verification.
#
# `credentialVerification.result: verified` is only meaningful once this has
# re-read the credential through the normal persisted OS-store lookup in a
# clean process (TM_TOKEN unset, not inherited from the configuring shell),
# revalidated it via /api/v1/me, and will authenticate the report with that
# exact same value. Never accepts the just-supplied candidate as proof.
# ---------------------------------------------------------------------------

readback_me() {
  local base_url="$1" config_file="$2"
  local tmp_script output
  tmp_script="$(mktemp)"
  chmod 600 "$tmp_script" 2>/dev/null || true
  cat > "$tmp_script" <<'SCRIPT'
set -eu
if [ -f "$TM_READBACK_CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$TM_READBACK_CONFIG_FILE" 2>/dev/null || { echo '{"reason":"config_unreadable"}'; exit 0; }
else
  echo '{"reason":"config_unreadable"}'
  exit 0
fi
if [ -z "${TM_TOKEN:-}" ]; then
  echo '{"reason":"missing_token"}'
  exit 0
fi
response="$(curl -fsS --max-time 15 -H "Authorization: Bearer $TM_TOKEN" "$TM_READBACK_BASE_URL/api/v1/me" 2>/dev/null)" || {
  echo '{"reason":"request_failed"}'
  exit 0
}
printf '%s' "$response"
SCRIPT
  output="$(env -u TM_TOKEN -u TM_INSTALL_PROMPT_TOKEN TM_READBACK_CONFIG_FILE="$config_file" TM_READBACK_BASE_URL="$base_url" bash "$tmp_script" 2>/dev/null || echo '{"reason":"request_failed"}')"
  rm -f "$tmp_script"
  printf '%s' "$output"
}

do_credential_verification() {
  local base_url="$1" expected_owner="$2"
  VERIFY_RESULT="failed"
  VERIFY_FAILURE_CODE="CREDENTIAL_VALIDATION_FAILED"
  VERIFY_GENERATION=""

  local raw kind
  raw="$(readback_me "$base_url" "$CONFIG_FILE")"
  kind="$(printf '%s' "$raw" | jq -r '.kind // empty' 2>/dev/null)"

  if [ "$kind" != "personal" ]; then
    local reason
    reason="$(printf '%s' "$raw" | jq -r '.reason // empty' 2>/dev/null)"
    case "$reason" in
      config_unreadable|missing_token) VERIFY_FAILURE_CODE="CREDENTIAL_STORE_UNREADABLE" ;;
      request_failed) VERIFY_FAILURE_CODE="CREDENTIAL_STORE_UNAVAILABLE" ;;
      *) VERIFY_FAILURE_CODE="CREDENTIAL_VALIDATION_FAILED" ;;
    esac
    return
  fi

  local owner gen
  owner="$(printf '%s' "$raw" | jq -r '.ownerId')"
  gen="$(printf '%s' "$raw" | jq -r '.generation')"
  if [ "$owner" != "$expected_owner" ]; then
    VERIFY_FAILURE_CODE="OWNER_OR_DEPLOYMENT_MISMATCH"
    return
  fi
  VERIFY_RESULT="verified"
  VERIFY_FAILURE_CODE=""
  VERIFY_GENERATION="$gen"
}

# ---------------------------------------------------------------------------
# Local state directories.
#
# `local_version_state_dir` tracks per-target installed version/digest and is
# keyed only by the deployment URL — always available, credential-independent,
# used to decide whether `update` may safely overwrite a target.
#
# `state_dir_for` is the owner-scoped installation identity/report state from
# POV-30/31 (installationId, sequence, pendingReport) — personal-key only.
# ---------------------------------------------------------------------------

generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | lower
    return
  fi
  local hex b1 b2 b3 b4 b5 v idx table
  hex="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  if [ -z "$hex" ] || [ "${#hex}" -lt 32 ]; then
    hex="$(printf '%s%s' "$$" "$(date +%s%N 2>/dev/null || date +%s)" | sha256_stdin | cut -c1-32)"
  fi
  b1="${hex:0:8}"; b2="${hex:8:4}"; b3="${hex:12:4}"; b4="${hex:16:4}"; b5="${hex:20:12}"
  b3="4${b3:1:3}"
  table="89ab"
  v="${b4:0:1}"
  case "$v" in
    [0-9]) idx=$((10#$v % 4)) ;;
    *) idx=$(( (16#$v) % 4 )) ;;
  esac
  v="${table:idx:1}"
  b4="${v}${b4:1:3}"
  printf '%s-%s-%s-%s-%s\n' "$b1" "$b2" "$b3" "$b4" "$b5" | lower
}

state_key_hash() {
  printf '%s' "$1" | sha256_stdin | cut -c1-32
}

local_version_state_dir() {
  printf '%s/_local/%s' "$TM_STATE_DIR" "$(state_key_hash "$1")"
}

state_dir_for() {
  printf '%s/%s' "$TM_STATE_DIR" "$(state_key_hash "$1|$2")"
}

state_lock_acquire() {
  local dir="$1" lock waited=0
  mkdir -p "$dir" 2>/dev/null || true
  chmod 700 "$dir" 2>/dev/null || true
  lock="$dir/.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -gt 50 ]; then
      echo "Error: could not acquire local state lock at $lock" >&2
      return 1
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  STATE_LOCK_HELD="$lock"
  return 0
}

state_lock_release() {
  [ -n "$STATE_LOCK_HELD" ] && rmdir "$STATE_LOCK_HELD" 2>/dev/null
  STATE_LOCK_HELD=""
}

state_file_path() {
  printf '%s/state.json' "$1"
}

state_read() {
  local f
  f="$(state_file_path "$1")"
  if [ -f "$f" ]; then cat "$f"; else printf '{}'; fi
}

state_write() {
  local dir="$1" json="$2" f tmp
  f="$(state_file_path "$dir")"
  mkdir -p "$dir" 2>/dev/null || true
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null || mktemp)"
  printf '%s' "$json" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f"
}

state_target_field() {
  local dir="$1" target="$2" field="$3" json
  json="$(state_read "$dir")"
  printf '%s' "$json" | jq -r --arg t "$target" --arg f "$field" '.targets[$t][$f] // empty' 2>/dev/null
}

state_record_target() {
  local dir="$1" target="$2" version="$3" sha="$4" json
  state_lock_acquire "$dir" || return 1
  json="$(state_read "$dir")"
  json="$(printf '%s' "$json" | jq --arg t "$target" --arg v "$version" --arg s "$sha" \
    '.targets = (.targets // {}) | .targets[$t] = {version:$v, sha256:$s}')"
  state_write "$dir" "$json"
  state_lock_release
}

ensure_installation_identity() {
  local dir="$1" json id
  state_lock_acquire "$dir" || return 1
  json="$(state_read "$dir")"
  id="$(printf '%s' "$json" | jq -r '.installationId // empty')"
  if [ -z "$id" ]; then
    id="$(generate_uuid)"
    json="$(printf '%s' "$json" | jq --arg id "$id" '.installationId = $id | .sequence = (.sequence // 0) | .targets = (.targets // {})')"
    state_write "$dir" "$json"
  fi
  INSTALLATION_ID="$id"
  state_lock_release
}

allocate_sequence() {
  local dir="$1" json seq
  state_lock_acquire "$dir" || return 1
  json="$(state_read "$dir")"
  seq="$(printf '%s' "$json" | jq -r '(.sequence // 0) + 1')"
  json="$(printf '%s' "$json" | jq --argjson s "$seq" '.sequence = $s')"
  state_write "$dir" "$json"
  state_lock_release
  printf '%s' "$seq"
}

save_retry_identity() {
  local dir="$1" base_url="$2" owner_id="$3" generation="$4" json
  state_lock_acquire "$dir" || return 1
  json="$(state_read "$dir")"
  json="$(printf '%s' "$json" | jq --arg d "$base_url" --arg o "$owner_id" --argjson g "$generation" \
    '.retryIdentity = {deploymentUrl:$d, ownerId:$o, generation:$g}')"
  state_write "$dir" "$json"
  state_lock_release
}

save_pending_report() {
  local dir="$1" seq="$2" body="$3" base_url="$4" owner_id="$5" generation="$6" json
  state_lock_acquire "$dir" || return 1
  json="$(state_read "$dir")"
  json="$(printf '%s' "$json" | jq \
    --argjson seq "$seq" --argjson body "$body" \
    --arg d "$base_url" --arg o "$owner_id" --argjson g "$generation" \
    '.pendingReport = {sequence:$seq, body:$body, retryIdentity:{deploymentUrl:$d, ownerId:$o, generation:$g}}')"
  state_write "$dir" "$json"
  state_lock_release
}

clear_pending_report() {
  local dir="$1" json
  state_lock_acquire "$dir" || return 1
  json="$(state_read "$dir")"
  json="$(printf '%s' "$json" | jq '.pendingReport = null')"
  state_write "$dir" "$json"
  state_lock_release
}

# ---------------------------------------------------------------------------
# Target file paths, staged/atomic replacement, and per-run result tracking.
# ---------------------------------------------------------------------------

target_content_path() {
  case "$1" in
    codex) printf '%s/.codex/tm-api.md' "$HOME" ;;
    claude) printf '%s/.claude/tm-api.md' "$HOME" ;;
    cursor) printf '%s/.cursor/rules/tm-api.md' "$HOME" ;;
  esac
}

ensure_registration() {
  local target="$1"
  case "$target" in
    codex)
      mkdir -p "$HOME/.codex" 2>/dev/null || return 1
      if ! grep -q "tm-api.md" "$HOME/.codex/AGENTS.md" 2>/dev/null; then
        { printf '\n@~/.codex/tm-api.md\n' >> "$HOME/.codex/AGENTS.md"; } 2>/dev/null || return 1
      fi
      ;;
    claude)
      mkdir -p "$HOME/.claude" 2>/dev/null || return 1
      if ! grep -q "tm-api.md" "$HOME/.claude/CLAUDE.md" 2>/dev/null; then
        { printf '\n@~/.claude/tm-api.md\n' >> "$HOME/.claude/CLAUDE.md"; } 2>/dev/null || return 1
      fi
      ;;
    cursor)
      mkdir -p "$HOME/.cursor/rules" 2>/dev/null || return 1
      ;;
  esac
  return 0
}

stage_target() {
  local target="$1" src="$2" content_path staged
  content_path="$(target_content_path "$target")"
  mkdir -p "$(dirname "$content_path")" 2>/dev/null || true
  staged="$(mktemp "${content_path}.XXXXXX.staged" 2>/dev/null || mktemp)"
  cp "$src" "$staged"
  chmod 600 "$staged" 2>/dev/null || true
  printf '%s' "$staged"
}

# Same-filesystem atomic rename per target (staged file lives beside its
# destination), with a backup restored if the follow-up registration edit
# fails. Other targets are never affected by one target's failure.
commit_target() {
  local target="$1" staged="$2" content_path backup err
  content_path="$(target_content_path "$target")"
  LAST_WRITE_FAILURE_CODE="UNKNOWN_ERROR"

  if ! mkdir -p "$(dirname "$content_path")" 2>/dev/null || [ ! -w "$(dirname "$content_path")" ]; then
    LAST_WRITE_FAILURE_CODE="WRITE_PERMISSION_DENIED"
    rm -f "$staged" 2>/dev/null
    return 1
  fi

  if [ -f "$content_path" ]; then
    backup="${content_path}.bak.$$"
    cp "$content_path" "$backup" 2>/dev/null || true
  fi

  if err="$(mv -f "$staged" "$content_path" 2>&1)"; then
    if ensure_registration "$target"; then
      [ -n "${backup:-}" ] && rm -f "$backup"
      return 0
    fi
    if [ -n "${backup:-}" ]; then mv -f "$backup" "$content_path"; else rm -f "$content_path"; fi
    LAST_WRITE_FAILURE_CODE="WRITE_PERMISSION_DENIED"
    return 1
  fi

  case "$err" in
    *"No space left"*) LAST_WRITE_FAILURE_CODE="DISK_FULL" ;;
    *"Permission denied"*) LAST_WRITE_FAILURE_CODE="WRITE_PERMISSION_DENIED" ;;
    *) LAST_WRITE_FAILURE_CODE="UNKNOWN_ERROR" ;;
  esac
  rm -f "$staged" 2>/dev/null
  return 1
}

append_target_result() {
  local target="$1" result="$2" observed="$3" attempted="$4" failure="$5"
  jq -nc --arg t "$target" --arg r "$result" --arg ov "$observed" --arg av "$attempted" --arg fc "$failure" \
    '{target:$t, result:$r}
     + (if $ov != "" then {observedVersion:$ov} else {} end)
     + (if $av != "" then {attemptedVersion:$av} else {} end)
     + (if $fc != "" then {failureCode:$fc} else {} end)' >> "$TARGET_RESULTS_FILE"
}

targets_json_array() {
  if [ -s "$TARGET_RESULTS_FILE" ]; then
    jq -s '.' "$TARGET_RESULTS_FILE" 2>/dev/null || echo '[]'
  else
    echo '[]'
  fi
}

resolve_target_list() {
  if [ -n "$OPT_TARGETS" ]; then
    printf '%s' "$OPT_TARGETS" | tr ',' ' '
  else
    printf 'codex claude cursor'
  fi
}

# ---------------------------------------------------------------------------
# Release manifest fetch/validation (GET /api/v1/skill-release, unauthenticated).
# ---------------------------------------------------------------------------

fetch_release_manifest() {
  local base_url="$1"
  curl -fsS --max-time 15 "$base_url/api/v1/skill-release" 2>/dev/null
}

# Validates the envelope and, when present, the release's own required
# scalar/contract fields. Sets RELEASE_PRESENT/RELEASE_COMPATIBLE/RELEASE_JSON.
# Per-target artifact validity is checked separately by release_target_available
# so one bad target never invalidates the whole manifest.
validate_release() {
  local json="$1" release
  RELEASE_PRESENT=0
  RELEASE_COMPATIBLE=0
  RELEASE_JSON=""

  printf '%s' "$json" | jq -e '.schemaVersion == 1' >/dev/null 2>&1 || return 1

  release="$(printf '%s' "$json" | jq -c '.release' 2>/dev/null)"
  if [ "$release" = "null" ] || [ -z "$release" ]; then
    return 0
  fi

  printf '%s' "$release" | jq -e \
    '(.releaseVersion|type=="number") and (.releaseVersion==(.releaseVersion|floor)) and .releaseVersion > 0' \
    >/dev/null 2>&1 || return 1
  printf '%s' "$release" | jq -e '.channel == "stable"' >/dev/null 2>&1 || return 1

  RELEASE_INSTALLER_VERSION="$(printf '%s' "$release" | jq -r '.installerVersion // empty')"
  is_stable_semver "$RELEASE_INSTALLER_VERSION" || return 1

  local report_contract manifest_contract tm_api_contract
  report_contract="$(printf '%s' "$release" | jq -r '.contractVersions.reportContractVersion // empty')"
  manifest_contract="$(printf '%s' "$release" | jq -r '.contractVersions.manifestContractVersion // empty')"
  tm_api_contract="$(printf '%s' "$release" | jq -r '.contractVersions.tmApiContractVersion // empty')"
  [[ "$report_contract" =~ ^[0-9]+$ ]] || return 1
  [[ "$manifest_contract" =~ ^[0-9]+$ ]] || return 1
  [[ "$tm_api_contract" =~ ^[0-9]+$ ]] || return 1

  RELEASE_JSON="$release"
  RELEASE_PRESENT=1
  RELEASE_COMPATIBLE=1
  if [ "$report_contract" != "$SUPPORTED_REPORT_CONTRACT_VERSION" ] || \
     [ "$manifest_contract" != "$SUPPORTED_MANIFEST_CONTRACT_VERSION" ] || \
     [ "$tm_api_contract" -gt "$SUPPORTED_TM_API_CONTRACT_VERSION" ]; then
    RELEASE_COMPATIBLE=0
  fi
  return 0
}

# Resolves target $1's artifact from the already-validated RELEASE_JSON.
# Requires exactly one "bundle" artifact for the target with a valid
# immutable https URL, 64-hex sha256, and positive size — never picks the
# first of several ambiguous candidates.
release_target_available() {
  local target="$1" version artifact_count kind url sha size
  [ "$RELEASE_PRESENT" = "1" ] || return 1
  [ "$RELEASE_COMPATIBLE" = "1" ] || return 1

  version="$(printf '%s' "$RELEASE_JSON" | jq -r ".targetVersions.$target // empty")"
  [ -n "$version" ] || return 1
  is_stable_semver "$version" || return 1

  artifact_count="$(printf '%s' "$RELEASE_JSON" | jq "[.artifacts[]? | select(.target==\"$target\")] | length")"
  [ "$artifact_count" = "1" ] || return 1

  kind="$(printf '%s' "$RELEASE_JSON" | jq -r "[.artifacts[] | select(.target==\"$target\")][0].kind")"
  [ "$kind" = "bundle" ] || return 1

  url="$(printf '%s' "$RELEASE_JSON" | jq -r "[.artifacts[] | select(.target==\"$target\")][0].url")"
  sha="$(printf '%s' "$RELEASE_JSON" | jq -r "[.artifacts[] | select(.target==\"$target\")][0].sha256")"
  size="$(printf '%s' "$RELEASE_JSON" | jq -r "[.artifacts[] | select(.target==\"$target\")][0].sizeBytes")"

  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] || return 1
  is_immutable_https_url "$url" || return 1

  RELEASE_TARGET_VERSION="$version"
  RELEASE_TARGET_URL="$url"
  RELEASE_TARGET_SHA256="$sha"
  RELEASE_TARGET_SIZE="$size"
  return 0
}

# ---------------------------------------------------------------------------
# Download, digest/size verification, and safe extraction.
# ---------------------------------------------------------------------------

download_release_artifact() {
  local url="$1" expected_sha="$2" expected_size="$3" out_file="$4" actual_size actual_sha

  curl -fsSL --proto '=https' --max-redirs 5 --connect-timeout 10 --max-time 120 \
    --max-filesize "$((expected_size + 1024))" \
    -o "$out_file" "$url" 2>/dev/null || return 1

  actual_size="$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')"
  [ "$actual_size" = "$expected_size" ] || return 1

  actual_sha="$(sha256_file "$out_file")" || return 1
  [ "$actual_sha" = "$expected_sha" ] || return 1
  return 0
}

# Rejects absolute paths, `..` traversal, symlinks/hardlinks/specials, and
# any entry outside the expected flat `tm-ai-skill-<version>/<file>` layout,
# before tar ever extracts a byte.
validate_archive_entries() {
  local archive="$1" listing line type_char entry_path
  listing="$(tar -tvzf "$archive" 2>/dev/null)" || return 1
  [ -n "$listing" ] || return 1

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    type_char="${line:0:1}"
    entry_path="${line##* }"
    case "$type_char" in
      d|-) : ;;
      *) return 1 ;;
    esac
    case "$entry_path" in
      /*) return 1 ;;
    esac
    case "$entry_path" in
      *..*) return 1 ;;
    esac
    if ! [[ "$entry_path" =~ ^tm-ai-skill-[0-9]+\.[0-9]+\.[0-9]+/([A-Za-z0-9_.-]+)?$ ]]; then
      return 1
    fi
  done <<< "$listing"
  return 0
}

extract_archive() {
  local archive="$1" dest="$2"
  mkdir -p "$dest" 2>/dev/null || return 1
  chmod 700 "$dest" 2>/dev/null || true
  tar -xzf "$archive" -C "$dest" --no-same-owner 2>/dev/null || tar -xzf "$archive" -C "$dest" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Per-target sync: legacy (unpinned `main`, first-install fallback only) and
# release-based (pinned, checksum-verified, version-tracked).
# ---------------------------------------------------------------------------

sync_targets_legacy() {
  local targets="$1" t tmp staged
  for t in $targets; do
    tmp="$(mktemp)"
    if curl -fsSL --max-time 30 -o "$tmp" "$SKILL_URL" 2>/dev/null; then
      staged="$(stage_target "$t" "$tmp")"
      rm -f "$tmp"
      if commit_target "$t" "$staged"; then
        append_target_result "$t" "success" "" "" ""
      else
        append_target_result "$t" "failed" "" "" "$LAST_WRITE_FAILURE_CODE"
      fi
    else
      rm -f "$tmp"
      append_target_result "$t" "failed" "" "" "NETWORK_ERROR"
    fi
  done
}

sync_targets_release() {
  local mode="$1" targets="$2" state_dir="$3" t
  local stage_root
  stage_root="$(mktemp -d)"
  chmod 700 "$stage_root" 2>/dev/null || true

  for t in $targets; do
    if ! release_target_available "$t"; then
      append_target_result "$t" "skipped" "" "" "UNSUPPORTED_TARGET"
      continue
    fi
    local url="$RELEASE_TARGET_URL" sha="$RELEASE_TARGET_SHA256" size="$RELEASE_TARGET_SIZE" version="$RELEASE_TARGET_VERSION"
    local content_path recorded_version recorded_digest current_digest decision
    content_path="$(target_content_path "$t")"
    recorded_version="$(state_target_field "$state_dir" "$t" version)"
    recorded_digest="$(state_target_field "$state_dir" "$t" sha256)"

    if [ "$mode" = "install" ] || [ "$mode" = "reconfigure" ]; then
      decision="proceed"
    elif [ ! -f "$content_path" ]; then
      decision="proceed"
    elif [ -z "$recorded_version" ]; then
      decision="skip_unknown"
    else
      current_digest="$(sha256_file "$content_path" 2>/dev/null || echo "")"
      if [ "$current_digest" != "$recorded_digest" ]; then
        decision="skip_unknown"
      else
        case "$(compare_installed_version "$recorded_version" "$version")" in
          update_available) decision="proceed" ;;
          *) decision="up_to_date" ;;
        esac
      fi
    fi

    case "$decision" in
      up_to_date)
        append_target_result "$t" "success" "$recorded_version" "" ""
        continue
        ;;
      skip_unknown)
        append_target_result "$t" "skipped" "$recorded_version" "$version" ""
        continue
        ;;
    esac

    local cache_id archive_path extract_dir
    cache_id="$(printf '%s|%s' "$url" "$sha" | sha256_stdin)"
    archive_path="$stage_root/${cache_id}.tar.gz"
    extract_dir="$stage_root/extracted-${cache_id}"

    if [ ! -f "$archive_path" ]; then
      if ! download_release_artifact "$url" "$sha" "$size" "$archive_path"; then
        append_target_result "$t" "failed" "" "$version" "DIGEST_MISMATCH"
        rm -f "$archive_path"
        continue
      fi
      if ! validate_archive_entries "$archive_path"; then
        append_target_result "$t" "failed" "" "$version" "DIGEST_MISMATCH"
        rm -f "$archive_path"
        continue
      fi
    fi

    if [ ! -d "$extract_dir" ]; then
      if ! extract_archive "$archive_path" "$extract_dir"; then
        append_target_result "$t" "failed" "" "$version" "UNKNOWN_ERROR"
        continue
      fi
    fi

    local skill_md
    skill_md="$(find "$extract_dir" -mindepth 1 -maxdepth 2 -name 'SKILL.md' 2>/dev/null | head -n1)"
    if [ -z "$skill_md" ]; then
      append_target_result "$t" "failed" "" "$version" "UNKNOWN_ERROR"
      continue
    fi

    local staged
    staged="$(stage_target "$t" "$skill_md")"
    if commit_target "$t" "$staged"; then
      local digest
      digest="$(sha256_file "$content_path")"
      state_record_target "$state_dir" "$t" "$version" "$digest"
      append_target_result "$t" "success" "$version" "$version" ""
    else
      append_target_result "$t" "failed" "" "$version" "$LAST_WRITE_FAILURE_CODE"
    fi
  done

  rm -rf "$stage_root" 2>/dev/null
}
