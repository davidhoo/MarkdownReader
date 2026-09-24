#!/usr/bin/env bash
# Homebrew Cask metadata helpers. Source this file; it does not run on its own.
# Local render/extract functions do not touch the network. homebrew_cask_sync
# talks to GitHub Contents API via `gh`.

homebrew_cask_validate_version() {
    local version="${1:-}"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "invalid Cask version '$version' (expected X.Y.Z)" >&2
        return 1
    fi
}

homebrew_cask_validate_sha256() {
    local sha256="${1:-}"
    if [[ ! "$sha256" =~ ^[a-f0-9]{64}$ ]]; then
        echo "invalid Cask sha256 '$sha256' (expected 64 lowercase hex chars)" >&2
        return 1
    fi
}

_homebrew_cask_count_anchored() {
    local content="$1"
    local pattern="$2"
    local count
    count="$(printf '%s\n' "$content" | grep -cE "$pattern" || true)"
    printf '%s\n' "$count"
}

homebrew_cask_render_metadata() {
    local content="$1"
    local version="$2"
    local sha256="$3"

    homebrew_cask_validate_version "$version" || return 1
    homebrew_cask_validate_sha256 "$sha256" || return 1

    local version_pattern='^[[:space:]]*version[[:space:]]+"[^"]+"[[:space:]]*$'
    local sha_pattern='^[[:space:]]*sha256[[:space:]]+"[^"]+"[[:space:]]*$'
    local version_count sha_count
    version_count="$(_homebrew_cask_count_anchored "$content" "$version_pattern")"
    sha_count="$(_homebrew_cask_count_anchored "$content" "$sha_pattern")"

    if [[ "$version_count" -ne 1 ]]; then
        echo "Cask must contain exactly one anchored version line (found $version_count)" >&2
        return 1
    fi
    if [[ "$sha_count" -ne 1 ]]; then
        echo "Cask must contain exactly one anchored sha256 line (found $sha_count)" >&2
        return 1
    fi

    printf '%s\n' "$content" | awk -v version="$version" -v sha256="$sha256" '
        /^[[:space:]]*version[[:space:]]+"/ {
            match($0, /^[[:space:]]*/)
            print substr($0, RSTART, RLENGTH) "version \"" version "\""
            next
        }
        /^[[:space:]]*sha256[[:space:]]+"/ {
            match($0, /^[[:space:]]*/)
            print substr($0, RSTART, RLENGTH) "sha256 \"" sha256 "\""
            next
        }
        { print }
    '
}

homebrew_cask_extract_version() {
    local content="$1"
    local matches
    matches="$(printf '%s\n' "$content" | sed -nE 's/^[[:space:]]*version[[:space:]]+"([^"]+)"[[:space:]]*$/\1/p')"
    if [[ -z "$matches" ]]; then
        echo "Cask has no anchored version line" >&2
        return 1
    fi
    if [[ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" -ne 1 ]]; then
        echo "Cask has multiple anchored version lines" >&2
        return 1
    fi
    printf '%s\n' "$matches"
}

homebrew_cask_extract_sha256() {
    local content="$1"
    local matches
    matches="$(printf '%s\n' "$content" | sed -nE 's/^[[:space:]]*sha256[[:space:]]+"([^"]+)"[[:space:]]*$/\1/p')"
    if [[ -z "$matches" ]]; then
        echo "Cask has no anchored sha256 line" >&2
        return 1
    fi
    if [[ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" -ne 1 ]]; then
        echo "Cask has multiple anchored sha256 lines" >&2
        return 1
    fi
    printf '%s\n' "$matches"
}

HOMEBREW_CASK_REPO="davidhoo/homebrew-markdownreader"
HOMEBREW_CASK_PATH="Casks/markdownreader.rb"
HOMEBREW_CASK_BRANCH="main"

_homebrew_cask_fail() {
    echo "Homebrew Cask sync failed for ${HOMEBREW_CASK_REPO}:${HOMEBREW_CASK_PATH}: $*" >&2
    return 1
}

_homebrew_cask_json_field() {
    python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]], end="")' "$1"
}

_homebrew_cask_decode_content() {
    python3 -c 'import json,base64,sys; print(base64.b64decode(json.load(sys.stdin)["content"]).decode(), end="")'
}

_homebrew_cask_put_payload() {
    local message="$1"
    local blob_sha="$2"
    local branch="$3"
    python3 -c '
import base64, json, sys
message, sha, branch = sys.argv[1], sys.argv[2], sys.argv[3]
raw = sys.stdin.buffer.read()
json.dump({
    "message": message,
    "content": base64.b64encode(raw).decode("ascii"),
    "sha": sha,
    "branch": branch,
}, sys.stdout)
' "$message" "$blob_sha" "$branch"
}

homebrew_cask_sync() {
    local version="${1:-}"
    local sha256="${2:-}"
    homebrew_cask_validate_version "$version" || return 1
    homebrew_cask_validate_sha256 "$sha256" || return 1

    local repo="$HOMEBREW_CASK_REPO"
    local path="$HOMEBREW_CASK_PATH"
    local branch="$HOMEBREW_CASK_BRANCH"
    local get_endpoint="repos/${repo}/contents/${path}?ref=${branch}"
    local put_endpoint="repos/${repo}/contents/${path}"
    local max_attempts=2
    local attempt response blob_sha content updated put_json put_output put_status
    local verified remote_version remote_sha

    for attempt in $(seq 1 "$max_attempts"); do
        response="$(command gh api "$get_endpoint")" || \
            _homebrew_cask_fail "unable to read current Cask" || return 1

        blob_sha="$(printf '%s' "$response" | _homebrew_cask_json_field sha)" || \
            _homebrew_cask_fail "Contents API response is missing sha" || return 1
        content="$(printf '%s' "$response" | _homebrew_cask_decode_content)" || \
            _homebrew_cask_fail "unable to decode Cask content" || return 1

        updated="$(homebrew_cask_render_metadata "$content" "$version" "$sha256")" || \
            _homebrew_cask_fail "remote Cask shape is invalid" || return 1

        put_json="$(printf '%s' "$updated" | _homebrew_cask_put_payload \
            "chore(cask): update markdownreader to v${version}" "$blob_sha" "$branch")" || \
            _homebrew_cask_fail "unable to encode write payload" || return 1

        put_status=0
        put_output="$(printf '%s' "$put_json" | command gh api --method PUT "$put_endpoint" --input - 2>&1)" || put_status=$?

        if [[ "$put_status" -ne 0 ]]; then
            if printf '%s' "$put_output" | grep -q 'HTTP 409' && [[ "$attempt" -lt "$max_attempts" ]]; then
                continue
            fi
            _homebrew_cask_fail "$put_output" || return 1
        fi

        response="$(command gh api "$get_endpoint")" || \
            _homebrew_cask_fail "unable to re-read Cask after write" || return 1
        verified="$(printf '%s' "$response" | _homebrew_cask_decode_content)" || \
            _homebrew_cask_fail "unable to decode Cask after write" || return 1
        remote_version="$(homebrew_cask_extract_version "$verified")" || \
            _homebrew_cask_fail "re-read Cask has no version" || return 1
        remote_sha="$(homebrew_cask_extract_sha256 "$verified")" || \
            _homebrew_cask_fail "re-read Cask has no sha256" || return 1

        if [[ "$remote_version" != "$version" || "$remote_sha" != "$sha256" ]]; then
            _homebrew_cask_fail "remote Cask is ${remote_version}/${remote_sha}, expected ${version}/${sha256}" || return 1
        fi
        return 0
    done

    _homebrew_cask_fail "content conflict after retry"
}
