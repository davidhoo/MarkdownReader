#!/usr/bin/env bash
# Tests for Homebrew Cask metadata helpers (no network).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/homebrew-cask-sync.sh"

# shellcheck source=../homebrew-cask-sync.sh
source "$HELPER"

PASS=0
FAIL=0

fail() {
    echo "FAIL: $*"
    FAIL=$((FAIL + 1))
}

pass() {
    echo "PASS: $*"
    PASS=$((PASS + 1))
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label"
        echo "  expected: $(printf '%q' "$expected")"
        echo "  actual:   $(printf '%q' "$actual")"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label"
        echo "  missing: $(printf '%q' "$needle")"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        fail "$label"
        echo "  unexpectedly found: $(printf '%q' "$needle")"
    else
        pass "$label"
    fi
}

assert_fails() {
    local label="$1"
    shift
    local output=""
    set +e
    output="$("$@" 2>&1)"
    local status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        pass "$label"
    else
        fail "$label (expected non-zero, got 0)"
        echo "  output: $output"
    fi
}

SAMPLE_CASK=$'cask "markdownreader" do\n  version "2.3.1"\n  sha256 "0b76c2f46c07fb88a42a900c9f0ac51247566f1930fca1d37c388a2a7467f14e"\n\n  url "https://github.com/davidhoo/MarkdownReader/releases/download/v#{version}/MarkdownReader.dmg",\n      verified: "github.com/davidhoo/MarkdownReader/"\n  name "Markdown Reader"\n  desc "Quiet Markdown reader"\n  homepage "https://davidhoo.github.io/MarkdownReader/"\n\n  livecheck do\n    url :url\n    strategy :github_latest\n  end\n\n  auto_updates true\n  depends_on arch: :arm64\nend\n'

NEW_VERSION="2.4.1"
NEW_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# --- rendering ---

rendered="$(homebrew_cask_render_metadata "$SAMPLE_CASK" "$NEW_VERSION" "$NEW_SHA256")"

assert_eq "$(homebrew_cask_extract_version "$rendered")" "$NEW_VERSION" \
    "render writes a single version field"
assert_eq "$(homebrew_cask_extract_sha256 "$rendered")" "$NEW_SHA256" \
    "render writes a single sha256 field"

version_lines="$(printf '%s\n' "$rendered" | grep -cE '^[[:space:]]*version[[:space:]]+"' || true)"
sha_lines="$(printf '%s\n' "$rendered" | grep -cE '^[[:space:]]*sha256[[:space:]]+"' || true)"
assert_eq "$version_lines" "1" "render keeps exactly one version line"
assert_eq "$sha_lines" "1" "render keeps exactly one sha256 line"

assert_contains "$rendered" 'url "https://github.com/davidhoo/MarkdownReader/releases/download/v#{version}/MarkdownReader.dmg"' \
    "render preserves url interpolation"
assert_contains "$rendered" 'name "Markdown Reader"' \
    "render preserves unrelated name line"
assert_contains "$rendered" 'depends_on arch: :arm64' \
    "render preserves unrelated depends_on line"
assert_not_contains "$rendered" \
    'sha256 "0b76c2f46c07fb88a42a900c9f0ac51247566f1930fca1d37c388a2a7467f14e"' \
    "render replaces the previous sha256"

# --- extraction from original ---

assert_eq "$(homebrew_cask_extract_version "$SAMPLE_CASK")" "2.3.1" \
    "extract reads the original version"
assert_eq "$(homebrew_cask_extract_sha256 "$SAMPLE_CASK")" \
    "0b76c2f46c07fb88a42a900c9f0ac51247566f1930fca1d37c388a2a7467f14e" \
    "extract reads the original sha256"

# --- validation ---

assert_fails "reject version that is not X.Y.Z" \
    homebrew_cask_render_metadata "$SAMPLE_CASK" "2.4" "$NEW_SHA256"
assert_fails "reject version with prefix" \
    homebrew_cask_render_metadata "$SAMPLE_CASK" "v2.4.1" "$NEW_SHA256"
assert_fails "reject uppercase sha256" \
    homebrew_cask_render_metadata "$SAMPLE_CASK" "$NEW_VERSION" \
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
assert_fails "reject short sha256" \
    homebrew_cask_render_metadata "$SAMPLE_CASK" "$NEW_VERSION" "abc"

# --- malformed Cask content ---

assert_fails "reject missing version line" \
    homebrew_cask_render_metadata $'cask "markdownreader" do\n  sha256 "0b76c2f46c07fb88a42a900c9f0ac51247566f1930fca1d37c388a2a7467f14e"\nend\n' \
    "$NEW_VERSION" "$NEW_SHA256"

assert_fails "reject missing sha256 line" \
    homebrew_cask_render_metadata $'cask "markdownreader" do\n  version "2.3.1"\nend\n' \
    "$NEW_VERSION" "$NEW_SHA256"

assert_fails "reject duplicated version lines" \
    homebrew_cask_render_metadata $'cask "markdownreader" do\n  version "2.3.1"\n  version "2.3.2"\n  sha256 "0b76c2f46c07fb88a42a900c9f0ac51247566f1930fca1d37c388a2a7467f14e"\nend\n' \
    "$NEW_VERSION" "$NEW_SHA256"

assert_fails "reject duplicated sha256 lines" \
    homebrew_cask_render_metadata $'cask "markdownreader" do\n  version "2.3.1"\n  sha256 "0b76c2f46c07fb88a42a900c9f0ac51247566f1930fca1d37c388a2a7467f14e"\n  sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"\nend\n' \
    "$NEW_VERSION" "$NEW_SHA256"

# --- mocked GitHub Contents API ---

if ! declare -F homebrew_cask_sync >/dev/null; then
    fail "homebrew_cask_sync is defined"
    echo
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

ORIG_PATH="$PATH"
INITIAL_BLOB_SHA="1111111111111111111111111111111111111111"
CONFLICT_BLOB_SHA="2222222222222222222222222222222222222222"
WRITTEN_BLOB_SHA="3333333333333333333333333333333333333333"
CASK_API_PATH="repos/davidhoo/homebrew-markdownreader/contents/Casks/markdownreader.rb"

json_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

decode_put_cask() {
    python3 -c 'import json,base64,sys; print(base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(), end="")' "$1"
}

install_mock_gh() {
    local conflict_remaining="$1"
    local mismatch_verify="$2"
    MOCK_DIR="$(mktemp -d)"
    export HOMEBREW_CASK_TEST_MOCK_DIR="$MOCK_DIR"
    export HOMEBREW_CASK_TEST_CONFLICT_SHA="$CONFLICT_BLOB_SHA"
    export HOMEBREW_CASK_TEST_WRITTEN_SHA="$WRITTEN_BLOB_SHA"
    printf '%s' "$SAMPLE_CASK" > "$MOCK_DIR/cask.rb"
    printf '%s\n' "$INITIAL_BLOB_SHA" > "$MOCK_DIR/blob_sha"
    printf '%s\n' "$conflict_remaining" > "$MOCK_DIR/conflict_remaining"
    printf '%s\n' "$mismatch_verify" > "$MOCK_DIR/mismatch_verify"
    printf '%s\n' "0" > "$MOCK_DIR/get_count"
    mkdir -p "$MOCK_DIR/puts"
    cat > "$MOCK_DIR/gh" << 'MOCK'
#!/usr/bin/env bash
set -euo pipefail
MOCK_DIR="${HOMEBREW_CASK_TEST_MOCK_DIR:?}"
printf '%s\n' "$*" >> "$MOCK_DIR/invocations"

method="GET"
endpoint=""
i=1
while [[ $i -le $# ]]; do
    arg="${!i}"
    case "$arg" in
        api) ;;
        --method|-X)
            i=$((i + 1))
            method="${!i}"
            ;;
        --input)
            i=$((i + 1))
            ;;
        repos/*)
            endpoint="$arg"
            ;;
    esac
    i=$((i + 1))
done

if [[ "$method" == "GET" ]]; then
    get_count="$(cat "$MOCK_DIR/get_count")"
    get_count=$((get_count + 1))
    printf '%s\n' "$get_count" > "$MOCK_DIR/get_count"
    mismatch="$(cat "$MOCK_DIR/mismatch_verify")"
    python3 - "$MOCK_DIR" "$get_count" "$mismatch" << 'PY'
import base64, json, pathlib, sys, textwrap
mock = pathlib.Path(sys.argv[1])
get_count = int(sys.argv[2])
mismatch = sys.argv[3] == "1"
text = mock.joinpath("cask.rb").read_text()
if mismatch and get_count >= 2:
    text = text.replace("2.4.1", "0.0.0")
raw = text.encode()
b64 = base64.b64encode(raw).decode()
wrapped = "\n".join(textwrap.wrap(b64, 60)) + "\n"
print(json.dumps({
    "sha": mock.joinpath("blob_sha").read_text().strip(),
    "content": wrapped,
    "encoding": "base64",
    "path": "Casks/markdownreader.rb",
}))
PY
    exit 0
fi

if [[ "$method" != "PUT" ]]; then
    echo "unexpected gh method $method" >&2
    exit 1
fi

payload="$(cat)"
put_index="$(find "$MOCK_DIR/puts" -name '*.json' | wc -l | tr -d ' ')"
put_index=$((put_index + 1))
printf '%s\n' "$payload" > "$MOCK_DIR/puts/$put_index.json"
printf '%s\n' "$endpoint" > "$MOCK_DIR/puts/$put_index.endpoint"

conflict_remaining="$(cat "$MOCK_DIR/conflict_remaining")"
if [[ "$conflict_remaining" -gt 0 ]]; then
    printf '%s\n' $((conflict_remaining - 1)) > "$MOCK_DIR/conflict_remaining"
    printf '%s\n' "# concurrent tap edit" >> "$MOCK_DIR/cask.rb"
    printf '%s\n' "${HOMEBREW_CASK_TEST_CONFLICT_SHA}" > "$MOCK_DIR/blob_sha"
    echo "gh: Conflict (HTTP 409)" >&2
    exit 1
fi

python3 - "$MOCK_DIR" "$put_index" "${HOMEBREW_CASK_TEST_WRITTEN_SHA}" << 'PY'
import base64, json, pathlib, sys
mock = pathlib.Path(sys.argv[1])
put_index = sys.argv[2]
new_sha = sys.argv[3]
payload = json.loads(mock.joinpath("puts", f"{put_index}.json").read_text())
raw = base64.b64decode(payload["content"])
mock.joinpath("cask.rb").write_bytes(raw)
mock.joinpath("blob_sha").write_text(new_sha + "\n")
print(json.dumps({"content": {"sha": new_sha}, "commit": {"message": payload["message"]}}))
PY
MOCK
    chmod +x "$MOCK_DIR/gh"
    PATH="$MOCK_DIR:$PATH"
}

cleanup_mock_gh() {
    PATH="$ORIG_PATH"
    unset HOMEBREW_CASK_TEST_MOCK_DIR HOMEBREW_CASK_TEST_CONFLICT_SHA HOMEBREW_CASK_TEST_WRITTEN_SHA
}

assert_sync_request_contract() {
    local put_json="$1"
    local expected_sha="$2"
    local label_prefix="$3"
    local endpoint
    endpoint="$(cat "${put_json%.json}.endpoint")"
    assert_contains "$endpoint" "$CASK_API_PATH" \
        "$label_prefix PUT targets Tap Cask path"
    assert_eq "$(json_field "$put_json" branch)" "main" \
        "$label_prefix PUT targets main"
    assert_eq "$(json_field "$put_json" sha)" "$expected_sha" \
        "$label_prefix PUT includes retrieved blob SHA"
    assert_eq "$(json_field "$put_json" message)" \
        "chore(cask): update markdownreader to v${NEW_VERSION}" \
        "$label_prefix PUT commit message includes the release version"
}

# Happy path + required API contract
install_mock_gh 0 0
set +e
sync_output="$(homebrew_cask_sync "$NEW_VERSION" "$NEW_SHA256" 2>&1)"
sync_status=$?
set -e
if [[ "$sync_status" -eq 0 ]]; then
    pass "sync succeeds when Contents API write is clean"
else
    fail "sync succeeds when Contents API write is clean"
    echo "  output: $sync_output"
fi
assert_contains "$(cat "$MOCK_DIR/invocations")" "${CASK_API_PATH}?ref=main" \
    "sync reads Casks/markdownreader.rb on main"
assert_sync_request_contract "$MOCK_DIR/puts/1.json" "$INITIAL_BLOB_SHA" "clean-write"
assert_eq "$(homebrew_cask_extract_version "$(decode_put_cask "$MOCK_DIR/puts/1.json")")" \
    "$NEW_VERSION" "clean-write PUT content version"
assert_eq "$(homebrew_cask_extract_sha256 "$(decode_put_cask "$MOCK_DIR/puts/1.json")")" \
    "$NEW_SHA256" "clean-write PUT content sha256"
cleanup_mock_gh

# One 409 conflict, then success on retry against latest remote text
install_mock_gh 1 0
set +e
sync_output="$(homebrew_cask_sync "$NEW_VERSION" "$NEW_SHA256" 2>&1)"
sync_status=$?
set -e
if [[ "$sync_status" -eq 0 ]]; then
    pass "sync retries a single 409 conflict"
else
    fail "sync retries a single 409 conflict"
    echo "  output: $sync_output"
fi
put_count="$(find "$MOCK_DIR/puts" -name '*.json' | wc -l | tr -d ' ')"
assert_eq "$put_count" "2" "conflict path performs exactly two PUTs"
assert_sync_request_contract "$MOCK_DIR/puts/1.json" "$INITIAL_BLOB_SHA" "conflict-first"
assert_sync_request_contract "$MOCK_DIR/puts/2.json" "$CONFLICT_BLOB_SHA" "conflict-retry"
assert_contains "$(decode_put_cask "$MOCK_DIR/puts/2.json")" "# concurrent tap edit" \
    "retry reapplies metadata onto the latest remote Cask text"
cleanup_mock_gh

# Successful write but mismatched re-read must fail
install_mock_gh 0 1
set +e
sync_output="$(homebrew_cask_sync "$NEW_VERSION" "$NEW_SHA256" 2>&1)"
sync_status=$?
set -e
if [[ "$sync_status" -ne 0 ]]; then
    pass "sync fails when re-read Cask metadata does not match"
else
    fail "sync fails when re-read Cask metadata does not match"
    echo "  output: $sync_output"
fi
assert_contains "$sync_output" "davidhoo/homebrew-markdownreader" \
    "mismatch error identifies the Tap"
assert_contains "$sync_output" "Casks/markdownreader.rb" \
    "mismatch error identifies the Cask path"
cleanup_mock_gh

echo
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
