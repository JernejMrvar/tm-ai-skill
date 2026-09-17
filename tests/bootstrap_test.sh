#!/usr/bin/env bash
set -euo pipefail

# Coverage for bootstrap.sh: the fixed template a Settings-generated
# install command renders (with placeholders substituted) and runs before
# install.sh itself is available on disk. Exercises both the fail-fast
# validation gates (no network involved) and, via a deterministic local
# `curl` stand-in, the full download -> digest/size check -> archive-safety
# check -> extract -> invoke(install.sh) pipeline — without any real network
# access or TLS (see the `curl` shim below for why real https: URL text is
# still required and asserted).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass_count=0

assert_fails() {
  local label="$1"
  shift
  if "$@" >"$TMP_ROOT/out" 2>&1; then
    printf 'not ok - %s\nexpected failure, but it succeeded\n' "$label" >&2
    cat "$TMP_ROOT/out" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

assert_succeeds() {
  local label="$1"
  shift
  if ! "$@" >"$TMP_ROOT/out" 2>&1; then
    printf 'not ok - %s\nexpected success, but it failed\n' "$label" >&2
    cat "$TMP_ROOT/out" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

assert_contains_file() {
  local needle="$1" file="$2" label="$3"
  if ! grep -qF "$needle" "$file" 2>/dev/null; then
    printf 'not ok - %s\nmissing: %s\n' "$label" "$needle" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$label"
}

# Renders bootstrap.sh with the given placeholder values into $1.
render_bootstrap() {
  local out="$1" base_url="$2" artifact_url="$3" sha="$4" size="$5" mode="$6"
  local installer_version="${7:-9.9.9}" target="${8:-codex}" snapshot="${9:-snapshot}"
  sed \
    -e "s#__TM_BASE_URL__#${base_url}#g" \
    -e "s#__ARTIFACT_URL__#${artifact_url}#g" \
    -e "s#__ARTIFACT_SHA256__#${sha}#g" \
    -e "s#__ARTIFACT_SIZE__#${size}#g" \
    -e "s#__INSTALLER_VERSION__#${installer_version}#g" \
    -e "s#__INSTALL_MODE__#${mode}#g" \
    -e "s#__TARGET__#${target}#g" \
    -e "s#__RELEASE_SNAPSHOT__#${snapshot}#g" \
    "$ROOT_DIR/bootstrap.sh" > "$out"
  chmod +x "$out"
}

# --- fail-fast validation gates (no network) --------------------------------

render_bootstrap "$TMP_ROOT/b1.sh" "https://example.test" "http://example.test/a.tar.gz" \
  "$(printf 'a%.0s' $(seq 1 64))" 100 install
assert_fails "rejects a non-https artifact URL" bash "$TMP_ROOT/b1.sh"
assert_contains_file "non-https" "$TMP_ROOT/out" "non-https rejection message is explicit"

render_bootstrap "$TMP_ROOT/b2.sh" "https://example.test" "https://example.test/releases/download/main/a.tar.gz" \
  "$(printf 'a%.0s' $(seq 1 64))" 100 install
assert_fails "rejects a mutable /main/ artifact URL" bash "$TMP_ROOT/b2.sh"

render_bootstrap "$TMP_ROOT/b3.sh" "https://example.test" "https://example.test/a.tar.gz" \
  "not-a-valid-sha" 100 install
assert_fails "rejects a malformed sha256" bash "$TMP_ROOT/b3.sh"

render_bootstrap "$TMP_ROOT/b4.sh" "https://example.test" "https://example.test/a.tar.gz" \
  "$(printf 'a%.0s' $(seq 1 64))" 0 install
assert_fails "rejects a zero artifact size" bash "$TMP_ROOT/b4.sh"

render_bootstrap "$TMP_ROOT/b5.sh" "https://example.test" "https://example.test/a.tar.gz" \
  "$(printf 'a%.0s' $(seq 1 64))" 100 update
assert_fails "rejects a mode other than install/reconfigure" bash "$TMP_ROOT/b5.sh"

# --- deterministic curl stand-in for the full pipeline ----------------------
#
# The `curl` shim below never sees a real network or TLS: it just copies a
# fixed local fixture file by the URL's basename, so bootstrap.sh's own
# https-only string check (asserted above) is what actually proves the
# scheme requirement — this shim only lets us exercise everything *after*
# that check (download/digest/size/archive-safety/extract/invoke) with a
# controlled artifact instead of a live server.

FIXTURE_DIR="$TMP_ROOT/fixtures"
mkdir -p "$FIXTURE_DIR"

BUILD_DIR="$TMP_ROOT/build/tm-ai-skill-9.9.9"
mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAKE_INSTALL_SH_INVOKED mode=$1 $2 $3 $4"
EOF
chmod +x "$BUILD_DIR/install.sh"
echo "fixture skill" > "$BUILD_DIR/SKILL.md"
echo "fixture readme" > "$BUILD_DIR/README.md"
echo "9.9.9" > "$BUILD_DIR/VERSION"
(cd "$TMP_ROOT/build" && tar czf "$FIXTURE_DIR/good.tar.gz" tm-ai-skill-9.9.9)

python3 "$ROOT_DIR/tests/fixtures/make_archive.py" "$FIXTURE_DIR/traversal.tar.gz" \
  "file:tm-ai-skill-9.9.9/install.sh" "file:tm-ai-skill-9.9.9/../../evil.txt" 2>/dev/null || \
  echo "(skipping traversal archive fixture: python3 unavailable)" > "$FIXTURE_DIR/traversal.tar.gz.skip"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else sha256sum "$1" | awk '{print $1}'; fi
}

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<SHIM
#!/usr/bin/env bash
# Deterministic local stand-in: ignores every flag, finds the last argument
# (the URL) and the value after -o, and copies a same-named fixture file.
out=""
url=""
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "-o" ]; then out="\$arg"; fi
  prev="\$arg"
  url="\$arg"
done
base="\$(basename "\$url")"
src="$FIXTURE_DIR/\$base"
if [ ! -f "\$src" ]; then
  echo "curl: (7) fake: no such fixture \$base" >&2
  exit 7
fi
cp "\$src" "\$out"
exit 0
SHIM
chmod +x "$FAKE_BIN/curl"

good_sha="$(sha256_of "$FIXTURE_DIR/good.tar.gz")"
good_size="$(wc -c < "$FIXTURE_DIR/good.tar.gz" | tr -d ' ')"

render_bootstrap "$TMP_ROOT/good.sh" "https://example.test" "https://example.test/good.tar.gz" \
  "$good_sha" "$good_size" install

PATH="$FAKE_BIN:$PATH" bash "$TMP_ROOT/good.sh" > "$TMP_ROOT/good.out" 2>&1
assert_contains_file "FAKE_INSTALL_SH_INVOKED mode=install --base-url=https://example.test" "$TMP_ROOT/good.out" \
  "a verified good artifact is extracted and install.sh is invoked with the handoff arguments"
assert_contains_file "mode=install --base-url=https://example.test --target=codex --release-snapshot=snapshot" "$TMP_ROOT/good.out" \
  "bootstrap forwards the selected target and release snapshot"

wrong_sha="${good_sha%?}0"
[ "$wrong_sha" = "$good_sha" ] && wrong_sha="${good_sha%?}1"
render_bootstrap "$TMP_ROOT/baddigest.sh" "https://example.test" "https://example.test/good.tar.gz" \
  "$wrong_sha" "$good_size" install
assert_fails "a downloaded artifact with the wrong sha256 is rejected before extraction" \
  env PATH="$FAKE_BIN:$PATH" bash "$TMP_ROOT/baddigest.sh"

if [ ! -f "$FIXTURE_DIR/traversal.tar.gz.skip" ]; then
  traversal_sha="$(sha256_of "$FIXTURE_DIR/traversal.tar.gz")"
  traversal_size="$(wc -c < "$FIXTURE_DIR/traversal.tar.gz" | tr -d ' ')"
  render_bootstrap "$TMP_ROOT/traversal.sh" "https://example.test" "https://example.test/traversal.tar.gz" \
    "$traversal_sha" "$traversal_size" install
  assert_fails "an archive with a path-traversal entry is rejected before extraction" \
    env PATH="$FAKE_BIN:$PATH" bash "$TMP_ROOT/traversal.sh"
  assert_contains_file "unexpected layout" "$TMP_ROOT/out" "traversal rejection message is explicit"
fi

printf '1..%d\n' "$pass_count"
