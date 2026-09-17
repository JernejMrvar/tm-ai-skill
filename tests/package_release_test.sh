#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass_count=0

ok() {
  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# Isolated throwaway repo mirroring this repo's packaging layout, so these
# tests never touch this repo's own working tree, history or tags.
REPO="$TMP_DIR/repo"
mkdir -p "$REPO/scripts"
cp "$ROOT_DIR/scripts/package-release.sh" "$REPO/scripts/package-release.sh"
chmod +x "$REPO/scripts/package-release.sh"

git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

printf '0.1.0' >"$REPO/VERSION"
printf '#!/usr/bin/env bash\necho install\n' >"$REPO/install.sh"
printf '# skill\n' >"$REPO/SKILL.md"
printf '# readme\n' >"$REPO/README.md"
# scripts/package-release.sh is repo-maintenance tooling, not shipped
# payload, so it is deliberately left untracked here — tracking it would
# itself trip the allowlist guard under test below.
git -C "$REPO" add VERSION install.sh SKILL.md README.md
git -C "$REPO" commit -q -m "baseline"
git -C "$REPO" tag v0.1.0

"$REPO/scripts/package-release.sh" v0.1.0 "$REPO/dist" >"$TMP_DIR/package-output.txt" 2>&1

ARCHIVE="$REPO/dist/tm-ai-skill-0.1.0.tar.gz"
MANIFEST="$REPO/dist/tm-ai-skill-0.1.0.manifest.json"

if [ -f "$ARCHIVE" ]; then
  ok "produces a version-named tarball"
else
  fail "produces a version-named tarball"
fi

if [ -f "$MANIFEST" ]; then
  ok "produces a manifest json"
else
  fail "produces a manifest json"
fi

EXPECTED_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if grep -Fq "$EXPECTED_SHA" "$MANIFEST"; then
  ok "manifest records the artifact's actual sha256"
else
  fail "manifest records the artifact's actual sha256"
fi

EXPECTED_SIZE="$(wc -c <"$ARCHIVE" | tr -d ' ')"
if grep -Fq "\"sizeBytes\": $EXPECTED_SIZE" "$MANIFEST"; then
  ok "manifest records the artifact's actual size"
else
  fail "manifest records the artifact's actual size"
fi

# An untracked file present in the working tree at packaging time (added
# after the archive above was already built) must never appear in it.
echo "TM_TOKEN=tm_should_never_ship" >"$REPO/.env"
if tar -tzf "$ARCHIVE" | grep -q '\.env$'; then
  fail "archive excludes untracked working-tree files"
else
  ok "archive excludes untracked working-tree files"
fi

# A file *tracked* elsewhere in the repo but outside the packaging allowlist
# (e.g. an accidentally committed config/credential file) must still never
# reach the archive — the explicit `git archive` pathspec is what actually
# enforces this, not a repo-wide policy that would break on ordinary
# repo-maintenance additions (tests, docs, CI config).
git -C "$REPO" checkout -q -b with-extra-file
echo "TM_TOKEN=tm_should_never_ship" >"$REPO/.tm-config"
git -C "$REPO" add .tm-config
git -C "$REPO" commit -q -m "accidentally track a config file"
git -C "$REPO" tag v0.2.0

"$REPO/scripts/package-release.sh" v0.2.0 "$REPO/dist" >/dev/null 2>&1
if tar -tzf "$REPO/dist/tm-ai-skill-0.1.0.tar.gz" | grep -q '\.tm-config$'; then
  fail "archive excludes a tracked file outside the packaging allowlist"
else
  ok "archive excludes a tracked file outside the packaging allowlist"
fi

# A ref missing the VERSION file entirely must also fail closed. Branches
# from the clean v0.1.0 baseline, not from with-extra-file above, so this
# checks the VERSION guard specifically rather than tripping the allowlist
# guard for an unrelated reason.
git -C "$REPO" checkout -q -b no-version v0.1.0
git -C "$REPO" rm -q VERSION
git -C "$REPO" commit -q -m "remove VERSION"
git -C "$REPO" tag v0.3.0-no-version

if "$REPO/scripts/package-release.sh" v0.3.0-no-version "$REPO/dist" >/dev/null 2>&1; then
  fail "packaging a ref without a VERSION file must fail"
else
  ok "packaging a ref without a VERSION file fails closed"
fi

# A non-SemVer VERSION content must fail closed, even if a matching (equally
# bogus) tag name was used for it — string equality between tag and VERSION
# is not proof the version itself is well-formed.
git -C "$REPO" checkout -q -b bad-version v0.1.0
printf 'banana' >"$REPO/VERSION"
git -C "$REPO" add VERSION
git -C "$REPO" commit -q -m "break VERSION"
git -C "$REPO" tag vbanana

if "$REPO/scripts/package-release.sh" vbanana "$REPO/dist" >/dev/null 2>&1; then
  fail "packaging a non-SemVer VERSION must fail"
else
  ok "packaging a non-SemVer VERSION fails closed"
fi

# A leading zero in any component violates SemVer spec item 2
# (https://semver.org/#spec-item-2) even though it matches a naive
# [0-9]+ regex — "01.2.3" must be rejected, not just non-digit garbage.
git -C "$REPO" checkout -q -b leading-zero-version v0.1.0
printf '01.2.3' >"$REPO/VERSION"
git -C "$REPO" add VERSION
git -C "$REPO" commit -q -m "introduce a leading-zero version"
git -C "$REPO" tag v01.2.3

if "$REPO/scripts/package-release.sh" v01.2.3 "$REPO/dist" >/dev/null 2>&1; then
  fail "packaging a VERSION with a leading zero must fail"
else
  ok "packaging a VERSION with a leading zero fails closed"
fi

# An annotated tag must resolve to the commit it points at, not the tag
# object's own SHA, in the manifest's "commit" field.
git -C "$REPO" checkout -q v0.1.0
git -C "$REPO" tag -a v0.1.0-annotated -m "annotated release tag"
EXPECTED_COMMIT="$(git -C "$REPO" rev-parse v0.1.0-annotated^{commit})"

"$REPO/scripts/package-release.sh" v0.1.0-annotated "$REPO/dist-annotated" >/dev/null 2>&1
RECORDED_COMMIT="$(grep -o '"commit": "[^"]*"' "$REPO/dist-annotated/tm-ai-skill-0.1.0.manifest.json" | cut -d'"' -f4)"

if [ "$RECORDED_COMMIT" = "$EXPECTED_COMMIT" ]; then
  ok "an annotated tag's manifest records the commit it points at, not the tag object"
else
  fail "an annotated tag's manifest records the commit it points at, not the tag object"
fi

echo "1..$pass_count"
