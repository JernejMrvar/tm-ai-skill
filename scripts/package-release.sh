#!/usr/bin/env bash
set -euo pipefail

# Packages a pinned git ref (tag or commit — never a branch name for a real
# release) of this repo into a versioned, checksummed release artifact for
# TestManagement's POV-30 release manifest to promote.
#
# Only the exact paths in ALLOWED_FILES, read from $REF via `git archive`,
# ever enter the artifact — never the working tree and never anything else
# tracked in the repo (tooling, docs, tests, CI config). So uncommitted
# edits, untracked local files (credentials, .DS_Store), and even an
# accidentally *committed* config/credential file elsewhere in the repo can
# never ride along. The post-build content check below verifies this held.

usage() {
  echo "Usage: $0 <git-ref> [output-dir]" >&2
  echo "  <git-ref>    A tag or commit to package (e.g. v0.1.0)." >&2
  echo "               Never pass 'main' or another branch name for a real release." >&2
  exit 1
}

REF="${1:-}"
[ -n "$REF" ] || usage
OUT_DIR="${2:-dist}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# `^{commit}` peels an annotated tag down to the commit it points at — a
# bare `git rev-parse "$REF"` on an annotated tag instead returns the tag
# *object's* own SHA, which would then be recorded as the manifest's
# "commit" and point at the wrong object type.
RESOLVED_SHA="$(git rev-parse "${REF}^{commit}")"

# $REF must name something immutable. A branch (or HEAD) can advance
# between this point and the `git show`/`git archive` calls below — package
# and record from RESOLVED_SHA everywhere after this, never $REF again, so
# the manifest's "commit" can never describe different bytes than what was
# actually archived.
if git show-ref --verify --quiet "refs/heads/$REF" ||
  git show-ref --verify --quiet "refs/remotes/origin/$REF" ||
  [ "$REF" = "HEAD" ]; then
  echo "error: '$REF' is a branch (or HEAD), not a pinned tag/commit" >&2
  echo "       packaging must reference an immutable ref that cannot move mid-run" >&2
  exit 1
fi

# Everything this repo currently distributes to Codex/Claude Code/Cursor.
# Update this list deliberately when the packaged file set changes.
ALLOWED_FILES=(install.sh SKILL.md README.md VERSION)

VERSION="$(git show "$RESOLVED_SHA:VERSION" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
  echo "error: VERSION file not found at $REF ($RESOLVED_SHA)" >&2
  exit 1
fi
# Plain X.Y.Z only — this repo's own releases are never prereleases, and
# TestManagementProject's promoted-manifest schema requires a genuine stable
# SemVer string for every version field. Reject garbage (e.g. "banana")
# before it can be packaged and published under a matching bad tag. Each
# component must be "0" or a digit sequence with no leading zero (SemVer
# spec item 2: https://semver.org/#spec-item-2) — a plain [0-9]+ would wrongly
# accept "01.2.3", which packages and tags successfully here but is then
# rejected by TestManagementProject's manifest validator at promotion time.
SEMVER_COMPONENT='(0|[1-9][0-9]*)'
if ! [[ "$VERSION" =~ ^${SEMVER_COMPONENT}\.${SEMVER_COMPONENT}\.${SEMVER_COMPONENT}$ ]]; then
  echo "error: VERSION '$VERSION' at $REF ($RESOLVED_SHA) is not a plain X.Y.Z SemVer string (no leading zeros)" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
ARCHIVE_NAME="tm-ai-skill-${VERSION}.tar.gz"
ARCHIVE_PATH="$OUT_DIR/$ARCHIVE_NAME"
PREFIX="tm-ai-skill-${VERSION}/"

# `git archive` errors out non-zero if any listed path doesn't exist at
# $RESOLVED_SHA, so a ref missing one of the expected payload files also
# fails here.
git archive --format=tar --prefix="$PREFIX" "$RESOLVED_SHA" -- "${ALLOWED_FILES[@]}" |
  gzip -9 >"$ARCHIVE_PATH"

# Verify what actually landed in the archive is exactly the allowlist, no
# more and no less — the real proof that nothing incidental (or a
# credential/config file tracked elsewhere in the repo) made it in.
EXPECTED_ENTRIES="$(
  { echo "$PREFIX"; printf '%s\n' "${ALLOWED_FILES[@]}" | sed "s#^#${PREFIX}#"; } | LC_ALL=C sort
)"
ACTUAL_ENTRIES="$(tar -tzf "$ARCHIVE_PATH" | LC_ALL=C sort)"
if [ "$EXPECTED_ENTRIES" != "$ACTUAL_ENTRIES" ]; then
  echo "error: packaged archive contents do not match the expected allowlist" >&2
  echo "expected:" >&2
  echo "$EXPECTED_ENTRIES" >&2
  echo "actual:" >&2
  echo "$ACTUAL_ENTRIES" >&2
  exit 1
fi

SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
SIZE_BYTES="$(wc -c <"$ARCHIVE_PATH" | tr -d ' ')"

FILES_JSON="$(printf '"%s", ' "${ALLOWED_FILES[@]}")"
FILES_JSON="[${FILES_JSON%, }]"

MANIFEST_PATH="$OUT_DIR/tm-ai-skill-${VERSION}.manifest.json"
cat >"$MANIFEST_PATH" <<JSON
{
  "installerVersion": "$VERSION",
  "commit": "$RESOLVED_SHA",
  "ref": "$REF",
  "artifact": {
    "kind": "bundle",
    "filename": "$ARCHIVE_NAME",
    "sha256": "$SHA256",
    "sizeBytes": $SIZE_BYTES
  },
  "files": $FILES_JSON
}
JSON

echo "Packaged $ARCHIVE_PATH"
echo "sha256:  $SHA256"
echo "size:    $SIZE_BYTES bytes"
echo "manifest: $MANIFEST_PATH"
