#!/usr/bin/env bash
set -euo pipefail

SKILL_URL="https://raw.githubusercontent.com/JernejMrvar/tm-ai-skill/main/SKILL.md"
DEFAULT_TM_BASE_URL="https://test-management-project.vercel.app"
CONFIG_FILE="${TM_CONFIG_FILE:-$HOME/.tm-config}"
CONFIG_BACKUP_TIMESTAMP="${CONFIG_BACKUP_TIMESTAMP:-}"
TM_INSTALL_TEST_MODE="${TM_INSTALL_TEST_MODE:-0}"
TM_INSTALL_TTY_PATH="${TM_INSTALL_TTY_PATH:-/dev/tty}"

PLATFORM=""
TM_SECRET_BACKEND_VALUE=""
TM_CREDENTIAL_TARGET_VALUE=""

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
        exit 1
      fi
      ;;
    windows-git-bash)
      if ! command -v powershell.exe >/dev/null 2>&1; then
        echo "Error: Windows Git Bash credential storage requires powershell.exe, but it was not found." >&2
        exit 1
      fi
      ;;
    unsupported-linux)
      echo "Error: Linux is not supported by this installer yet. No files were changed." >&2
      exit 1
      ;;
    unsupported-wsl)
      echo "Error: WSL is not supported by this installer. Run it from macOS or Windows Git Bash. No files were changed." >&2
      exit 1
      ;;
    *)
      echo "Error: unsupported platform for this installer. No files were changed." >&2
      exit 1
      ;;
  esac
}

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
  local prompt="${1:-Paste your TestManagement API token (starts with tm_): }"
  local allow_empty="${2:-0}"
  local existing_token="${3:-}"
  local token=""

  if [ "$TM_INSTALL_TEST_MODE" = "1" ] && [ "${TM_INSTALL_PROMPT_TOKEN+x}" = "x" ]; then
    token="$TM_INSTALL_PROMPT_TOKEN"
  elif ! { printf '%s' "$prompt" > "$TM_INSTALL_TTY_PATH" && IFS= read -rs token < "$TM_INSTALL_TTY_PATH" && printf '\n' > "$TM_INSTALL_TTY_PATH"; } 2>/dev/null; then
    if [ "$allow_empty" = "1" ] && [ -n "$existing_token" ]; then
      echo "Error: TM_TOKEN is already stored, but /dev/tty is unavailable to confirm whether to reuse or replace it." >&2
      echo "Run the installer from an interactive terminal, then press Enter to reuse it or paste a new tm_ token." >&2
      return 1
    fi
    echo "Error: no stored token was found and /dev/tty is unavailable for a secure prompt." >&2
    echo "Run the installer from an interactive terminal or migrate an existing TM_TOKEN in ~/.tm-config." >&2
    return 1
  fi

  if [ -z "$token" ] && [ "$allow_empty" = "1" ] && [ -n "$existing_token" ]; then
    printf '%s\n' "$existing_token"
    return 0
  fi

  if [[ "$token" != tm_* ]]; then
    echo "Error: token must start with tm_." >&2
    return 1
  fi

  printf '%s\n' "$token"
}

prompt_new_or_existing_token() {
  local existing_token="$1"

  prompt_token "A TM_TOKEN is already stored. Paste a new token to replace it, or press Enter to reuse it: " "1" "$existing_token"
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

install_skill_docs() {
  echo "Installing TestManagement AI skill..."

  # SKILL.md is the source distributed to each supported AI tool.
  mkdir -p "$HOME/.codex"
  curl -fsSL -o "$HOME/.codex/tm-api.md" "$SKILL_URL"

  if ! grep -q "tm-api.md" "$HOME/.codex/AGENTS.md" 2>/dev/null; then
    echo "" >> "$HOME/.codex/AGENTS.md"
    echo "@~/.codex/tm-api.md" >> "$HOME/.codex/AGENTS.md"
  fi
  echo "✓ Codex: skill registered in ~/.codex/AGENTS.md"

  mkdir -p "$HOME/.claude"
  curl -fsSL -o "$HOME/.claude/tm-api.md" "$SKILL_URL"

  if ! grep -q "tm-api.md" "$HOME/.claude/CLAUDE.md" 2>/dev/null; then
    echo "" >> "$HOME/.claude/CLAUDE.md"
    echo "@~/.claude/tm-api.md" >> "$HOME/.claude/CLAUDE.md"
  fi
  echo "✓ Claude Code: skill registered in ~/.claude/CLAUDE.md"

  mkdir -p "$HOME/.cursor/rules"
  curl -fsSL -o "$HOME/.cursor/rules/tm-api.md" "$SKILL_URL"
  echo "✓ Cursor: skill saved to ~/.cursor/rules/tm-api.md"
}

resolve_base_url() {
  local value
  value="$(read_existing_config_value TM_BASE_URL "$CONFIG_FILE" 2>/dev/null || true)"
  value="${value:-$DEFAULT_TM_BASE_URL}"
  strip_trailing_slashes "$value"
}

resolve_token() {
  local base_url="$1"
  local existing_token stored_token target

  existing_token="$(read_existing_config_value TM_TOKEN "$CONFIG_FILE" 2>/dev/null || true)"
  if [[ "$existing_token" == tm_* ]]; then
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
    if [[ "$stored_token" == tm_* ]]; then
      prompt_new_or_existing_token "$stored_token"
      return
    elif [ -n "$stored_token" ]; then
      echo "Warning: stored credential does not start with tm_; prompting for a replacement." >&2
    fi
  fi

  prompt_required_token
}

main() {
  detect_platform >/dev/null
  ensure_supported_platform

  local base_url token
  base_url="$(resolve_base_url)"
  credential_target "$base_url" >/dev/null
  token="$(resolve_token "$base_url")"

  store_secret "$base_url" "$token"
  echo "✓ Stored TM_TOKEN in $TM_SECRET_BACKEND_VALUE"

  backup_existing_config "$CONFIG_FILE"
  write_config "$CONFIG_FILE" "$base_url"
  install_skill_docs

  if validate_connection "$CONFIG_FILE"; then
    echo "✓ Verified API connection"
  else
    echo "Warning: installed credentials and config, but API validation failed." >&2
    echo "Check the token, TM_BASE_URL, and credential lookup troubleshooting in the README." >&2
  fi

  echo ""
  echo "Done. Restart Codex, Cursor, or Claude Code before using the skill."
  echo ""
  echo "Then start by asking your AI something like:"
  echo '  "List my TestManagement folders"'
  echo '  "Show test cases in the Login folder"'
  echo '  "Create a smoke test case for user login"'
}

if [ "$TM_INSTALL_TEST_MODE" != "1" ]; then
  main "$@"
fi
