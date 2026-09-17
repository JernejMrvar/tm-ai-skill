#!/usr/bin/env bash
# tm-ai-skill versioned bootstrap template.
#
# This file is the canonical source for the small, fixed bootstrap script
# that TestManagement's Settings page (a separate app-repo command builder,
# not implemented in this repository) renders into the copyable "install
# this skill" command. It is NOT part of the packaged release bundle (see
# scripts/package-release.sh's ALLOWED_FILES) and is never itself
# downloaded by an end user at install time — the command builder
# substitutes the placeholders below and inlines the *result* directly
# into the generated shell command, so running that command needs no extra
# network fetch to obtain this template and no execution on the server.
#
# Placeholders (substituted by the command builder before rendering; this
# file is never executed as-is with the literal placeholder text):
#   __TM_BASE_URL__      canonical deployment URL, already validated server-side
#   __ARTIFACT_URL__     immutable https release asset URL for the installer bundle
#   __ARTIFACT_SHA256__  expected lowercase 64-hex sha256 of that exact artifact
#   __ARTIFACT_SIZE__    expected exact byte size of that artifact
#   __INSTALLER_VERSION__ stable SemVer version embedded in the bundle
#   __INSTALL_MODE__     "install" or "reconfigure" — never update/check/retry-report
#   __TARGET__           selected target: codex, claude or cursor
#   __RELEASE_SNAPSHOT__ exact `{schemaVersion, release}` envelope selected by Settings
#
# The one-time personal key itself is never interpolated into this
# template; it is piped to the extracted install.sh over stdin by whatever
# invokes the rendered script, e.g.:
#
#   printf '%s' "$ONE_TIME_KEY" | bash -c "$(cat rendered-bootstrap.sh)"
#
# Never embed the key as a URL, a --token argument, or an interpolated
# string anywhere in the rendered output — stdin only. A dismissed/expired
# copyable command cannot be recovered; a new one requires explicit
# rotation of the one-time key server-side.
set -euo pipefail

TM_BOOTSTRAP_BASE_URL="__TM_BASE_URL__"
TM_BOOTSTRAP_ARTIFACT_URL="__ARTIFACT_URL__"
TM_BOOTSTRAP_ARTIFACT_SHA256="__ARTIFACT_SHA256__"
TM_BOOTSTRAP_ARTIFACT_SIZE="__ARTIFACT_SIZE__"
TM_BOOTSTRAP_INSTALLER_VERSION="__INSTALLER_VERSION__"
TM_BOOTSTRAP_MODE="__INSTALL_MODE__"
TM_BOOTSTRAP_TARGET="__TARGET__"
TM_BOOTSTRAP_RELEASE_SNAPSHOT="__RELEASE_SNAPSHOT__"

for cmd in curl tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is required but was not found." >&2
    exit 2
  fi
done

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "Error: neither shasum nor sha256sum is available." >&2
    exit 2
  fi
}

case "$TM_BOOTSTRAP_ARTIFACT_URL" in
  https://*) : ;;
  *)
    echo "Error: refusing a non-https bootstrap artifact URL." >&2
    exit 2
    ;;
esac
case "$TM_BOOTSTRAP_ARTIFACT_URL" in
  */main/*|*/latest/*|*/master/*|*/head/*|*/trunk/*)
    echo "Error: refusing a mutable main/latest/master/head/trunk artifact URL." >&2
    exit 2
    ;;
esac
if ! [[ "$TM_BOOTSTRAP_ARTIFACT_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Error: pinned sha256 is not a 64-character lowercase hex digest." >&2
  exit 2
fi
if ! [[ "$TM_BOOTSTRAP_ARTIFACT_SIZE" =~ ^[0-9]+$ ]] || [ "$TM_BOOTSTRAP_ARTIFACT_SIZE" -le 0 ]; then
  echo "Error: pinned artifact size is not a positive integer." >&2
  exit 2
fi
if ! [[ "$TM_BOOTSTRAP_INSTALLER_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
  echo "Error: pinned installer version is not a stable SemVer value." >&2
  exit 2
fi
case "$TM_BOOTSTRAP_MODE" in
  install|reconfigure) : ;;
  *)
    echo "Error: bootstrap only ever runs install or reconfigure, never update/check/retry-report." >&2
    exit 2
    ;;
esac
case "$TM_BOOTSTRAP_TARGET" in
  codex|claude|cursor) : ;;
  *)
    echo "Error: bootstrap target is not supported." >&2
    exit 2
    ;;
esac
if [ -z "$TM_BOOTSTRAP_RELEASE_SNAPSHOT" ]; then
  echo "Error: the selected release snapshot is missing." >&2
  exit 2
fi

TM_BOOTSTRAP_TMPDIR="$(mktemp -d)"
chmod 700 "$TM_BOOTSTRAP_TMPDIR" 2>/dev/null || true
cleanup() { rm -rf "$TM_BOOTSTRAP_TMPDIR"; }
trap cleanup EXIT INT TERM

ARCHIVE_PATH="$TM_BOOTSTRAP_TMPDIR/artifact.tar.gz"

# Never a bearer/Authorization header here — artifact hosts never see the
# credential. Bounded redirects/time/size; https-only end to end (no
# downgrade to http on redirect).
curl -fsSL --proto '=https' --max-redirs 5 --connect-timeout 10 --max-time 120 \
  --max-filesize "$((TM_BOOTSTRAP_ARTIFACT_SIZE + 1024))" \
  -o "$ARCHIVE_PATH" "$TM_BOOTSTRAP_ARTIFACT_URL"

ACTUAL_SIZE="$(wc -c < "$ARCHIVE_PATH" | tr -d ' ')"
if [ "$ACTUAL_SIZE" != "$TM_BOOTSTRAP_ARTIFACT_SIZE" ]; then
  echo "Error: downloaded artifact size ($ACTUAL_SIZE) does not match the pinned size ($TM_BOOTSTRAP_ARTIFACT_SIZE)." >&2
  exit 1
fi

ACTUAL_SHA256="$(sha256_of "$ARCHIVE_PATH")"
if [ "$ACTUAL_SHA256" != "$TM_BOOTSTRAP_ARTIFACT_SHA256" ]; then
  echo "Error: downloaded artifact checksum does not match the pinned sha256." >&2
  exit 1
fi

# The publisher creates exactly this directory and these four files. Comparing
# the complete name listing catches absolute/traversal paths, duplicates and
# unexpected entries before tar extracts anything, and binds the archive
# directory to the installer version in the selected release snapshot.
EXPECTED_ROOT="tm-ai-skill-${TM_BOOTSTRAP_INSTALLER_VERSION}"
EXPECTED_ENTRIES="$(printf '%s\n' \
  "${EXPECTED_ROOT}/" \
  "${EXPECTED_ROOT}/install.sh" \
  "${EXPECTED_ROOT}/SKILL.md" \
  "${EXPECTED_ROOT}/README.md" \
  "${EXPECTED_ROOT}/VERSION" | LC_ALL=C sort)"
if ! ACTUAL_ENTRIES="$(tar -tzf "$ARCHIVE_PATH" 2>/dev/null | LC_ALL=C sort)"; then
  echo "Error: release artifact could not be listed safely; refusing to extract." >&2
  exit 1
fi
if [ "$ACTUAL_ENTRIES" != "$EXPECTED_ENTRIES" ]; then
  echo "Error: release artifact has an unexpected layout or file set; refusing to extract." >&2
  exit 1
fi

# Tar name listings alone cannot distinguish regular files from links/specials.
# Inspect the verbose type and size fields as well, and cap the total declared
# uncompressed payload to prevent a small compressed archive from expanding
# without bound. The two size layouts below cover BSD tar (macOS) and GNU tar
# (Git Bash/Linux); an unknown listing format fails closed.
if ! ARCHIVE_LISTING="$(tar -tvzf "$ARCHIVE_PATH" 2>/dev/null)" || [ -z "$ARCHIVE_LISTING" ]; then
  echo "Error: release artifact could not be inspected safely; refusing to extract." >&2
  exit 1
fi
if ! printf '%s\n' "$ARCHIVE_LISTING" | awk -v max_bytes=$((16 * 1024 * 1024)) '
  {
    type_char = substr($1, 1, 1)
    if (type_char != "d" && type_char != "-") invalid = 1

    size = ""
    if ($2 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/) {
      size = $5
    } else if ($3 ~ /^[0-9]+$/) {
      size = $3
    } else {
      invalid = 1
    }

    if (size != "") {
      if (size > max_bytes || total > max_bytes - size) {
        invalid = 1
      } else {
        total += size
      }
    }
  }
  END { exit invalid ? 1 : 0 }
'; then
  echo "Error: release artifact contains links, special files, or an oversized payload; refusing to extract." >&2
  exit 1
fi

# The package VERSION file is part of the digest-protected payload. Check it
# before extraction so a mismatched runtime version cannot be launched.
if ! ARCHIVE_VERSION="$(tar -xOzf "$ARCHIVE_PATH" "${EXPECTED_ROOT}/VERSION" 2>/dev/null)"; then
  echo "Error: release artifact VERSION metadata could not be read; refusing to extract." >&2
  exit 1
fi
if [ "$ARCHIVE_VERSION" != "$TM_BOOTSTRAP_INSTALLER_VERSION" ]; then
  echo "Error: release artifact VERSION does not match the pinned installer version; refusing to extract." >&2
  exit 1
fi

EXTRACT_DIR="$TM_BOOTSTRAP_TMPDIR/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

INSTALLER_DIR="$EXTRACT_DIR/$EXPECTED_ROOT"
INSTALL_SH="$INSTALLER_DIR/install.sh"
if [ ! -d "$INSTALLER_DIR" ] || [ ! -f "$INSTALL_SH" ] || [ -L "$INSTALL_SH" ]; then
  echo "Error: extracted release artifact did not contain its validated installer path." >&2
  exit 1
fi
chmod +x "$INSTALL_SH"

# The one-time key arrives on this process's stdin (never as an argument,
# never interpolated into this script's own text) and is forwarded
# unchanged to the verified, pinned installer. Keep this process alive so
# the EXIT trap removes the staging directory, while preserving the child's
# exact exit status for the caller.
if "$INSTALL_SH" "$TM_BOOTSTRAP_MODE" "--base-url=$TM_BOOTSTRAP_BASE_URL" "--target=$TM_BOOTSTRAP_TARGET" "--release-snapshot=$TM_BOOTSTRAP_RELEASE_SNAPSHOT"; then
  INSTALLER_STATUS=0
else
  INSTALLER_STATUS=$?
fi
exit "$INSTALLER_STATUS"
