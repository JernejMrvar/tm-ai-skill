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
#   __INSTALL_MODE__     "install" or "reconfigure" — never update/check/retry-report
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
TM_BOOTSTRAP_MODE="__INSTALL_MODE__"

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
case "$TM_BOOTSTRAP_MODE" in
  install|reconfigure) : ;;
  *)
    echo "Error: bootstrap only ever runs install or reconfigure, never update/check/retry-report." >&2
    exit 2
    ;;
esac

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

# Reject anything but plain files/dirs, or an absolute/traversal path,
# before tar ever extracts a byte — mirrors install.sh's own
# validate_archive_entries so the bootstrap stage has the same guarantee
# even before install.sh itself is available to run it.
UNSAFE=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  type_char="${line:0:1}"
  entry_path="${line##* }"
  case "$type_char" in
    d|-) : ;;
    *) UNSAFE=1 ;;
  esac
  case "$entry_path" in
    /*) UNSAFE=1 ;;
  esac
  case "$entry_path" in
    *..*) UNSAFE=1 ;;
  esac
done <<EOF_LISTING
$(tar -tvzf "$ARCHIVE_PATH" 2>/dev/null)
EOF_LISTING
if [ "$UNSAFE" != "0" ]; then
  echo "Error: release artifact contains an unsafe archive entry; refusing to extract." >&2
  exit 1
fi

EXTRACT_DIR="$TM_BOOTSTRAP_TMPDIR/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

INSTALL_SH="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 2 -name 'install.sh' 2>/dev/null | head -n1)"
if [ -z "$INSTALL_SH" ]; then
  echo "Error: extracted artifact did not contain install.sh." >&2
  exit 1
fi
chmod +x "$INSTALL_SH"

# The one-time key arrives on this process's stdin (never as an argument,
# never interpolated into this script's own text) and is forwarded
# unchanged to the verified, pinned installer.
exec "$INSTALL_SH" "$TM_BOOTSTRAP_MODE" "--base-url=$TM_BOOTSTRAP_BASE_URL"
