#!/usr/bin/env bash

cache_root() {
    echo "${GH_WT_CACHE:-$HOME/.cache/gh-wt}"
}

# Portable sha1 hasher: Linux ships `sha1sum`, macOS ships `shasum`.
_sha1() {
    if command -v sha1sum >/dev/null 2>&1; then
        sha1sum
    else
        shasum -a 1
    fi
}

repo_id() {
    local repo="$1"
    printf '%s' "$repo" | _sha1 | cut -d' ' -f1
}

repo_cache_dir() {
    local repo="$1"
    echo "$(cache_root)/$(repo_id "$repo")"
}

ref_dir() {
    local repo="$1" tree_sha="$2"
    echo "$(repo_cache_dir "$repo")/ref/$tree_sha"
}

sessions_dir() {
    local repo="$1"
    echo "$(repo_cache_dir "$repo")/sessions"
}

session_dir() {
    local repo="$1" sid="$2"
    echo "$(sessions_dir "$repo")/$sid"
}

ensure_cache_dirs() {
    local repo="$1"
    local base
    base=$(repo_cache_dir "$repo")
    mkdir -p "$base/ref" "$base/sessions" \
        || die "cannot create cache at $base"
}

sanitize_branch() {
    echo "$1" | tr '/: ' '___'
}

main_repo() {
    local common
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
        || return 1
    [[ -n "$common" ]] || return 1
    dirname "$common"
}

require_main_repo() {
    local repo
    repo=$(main_repo) || die "not inside a git repository"
    echo "$repo"
}

session_id_from_gitfile() {
    local mountpoint="$1"
    local line
    line=$(head -n1 "$mountpoint/.git" 2>/dev/null) || return 1
    [[ "$line" == gitdir:* ]] || return 1
    basename "${line#gitdir: }"
}
