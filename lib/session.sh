#!/usr/bin/env bash

: "${GH_WT_CACHE_ROOT:=${XDG_CACHE_HOME:-$HOME/.cache}/gh-wt}"

sha1_of() {
    if command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha1sum | awk '{print $1}'
    else
        printf '%s' "$1" | shasum -a 1 | awk '{print $1}'
    fi
}

repo_id() {
    local abs
    abs=$(cd "$1" && pwd -P)
    sha1_of "$abs"
}

cache_dir_for_repo() {
    printf '%s/%s' "$GH_WT_CACHE_ROOT" "$(repo_id "$1")"
}

sanitize_sid() {
    printf '%s' "$1" | tr '/' '-' | tr -c 'A-Za-z0-9._-' '_'
}

unique_sid() {
    local cache="$1" base="$2" sid="$2" i=2
    while [[ -e "$cache/sessions/$sid" ]]; do
        sid="${base}-${i}"
        i=$((i + 1))
    done
    printf '%s\n' "$sid"
}

default_mountpoint() {
    local repo="$1" branch="$2"
    local parent base
    parent=$(dirname "$repo")
    base=$(printf '%s' "$branch" | tr '/' '-')
    printf '%s/%s\n' "$parent" "$base"
}

resolve_tree_sha() {
    local repo="$1" branch="$2" sha
    if sha=$(cd "$repo" && git rev-parse --verify "${branch}^{tree}" 2>/dev/null); then
        printf '%s\n' "$sha"
        return 0
    fi
    if sha=$(cd "$repo" && git rev-parse --verify "origin/${branch}^{tree}" 2>/dev/null); then
        printf '%s\n' "$sha"
        return 0
    fi
    return 1
}

ensure_reference() {
    local repo="$1" committish="$2" ref_dir="$3"
    if [[ -d "$ref_dir" ]] && [[ -n "$(ls -A "$ref_dir" 2>/dev/null)" ]]; then
        return 0
    fi
    local tmp
    tmp="${ref_dir}.tmp.$$"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    if ! (cd "$repo" && git archive --format=tar "$committish") | tar -x -C "$tmp"; then
        rm -rf "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$ref_dir")"
    if ! mv "$tmp" "$ref_dir" 2>/dev/null; then
        if [[ -d "$ref_dir" ]] && [[ -n "$(ls -A "$ref_dir" 2>/dev/null)" ]]; then
            rm -rf "$tmp"
            return 0
        fi
        rm -rf "$tmp"
        return 1
    fi
}

session_add() {
    local repo="$1" branch="$2" mountpoint="$3"

    if [[ -f "$repo/.gitmodules" ]]; then
        echo "Error: repositories with submodules are not supported in v0" >&2
        return 1
    fi

    if [[ -e "$mountpoint" ]] && [[ -n "$(ls -A "$mountpoint" 2>/dev/null)" ]]; then
        echo "Error: mountpoint '$mountpoint' already exists and is not empty" >&2
        return 1
    fi

    overlay_precheck || return 1

    local cache sid session_dir upper workdir
    cache=$(cache_dir_for_repo "$repo")
    sid=$(unique_sid "$cache" "$(sanitize_sid "$(basename "$mountpoint")")")
    session_dir="$cache/sessions/$sid"
    upper="$session_dir/upper"
    workdir="$session_dir/workdir"

    mkdir -p "$upper" "$workdir"
    mkdir -p "$mountpoint"

    local add_args=()
    if (cd "$repo" && git show-ref --verify --quiet "refs/heads/$branch"); then
        add_args=(--no-checkout "$mountpoint" "$branch")
    elif (cd "$repo" && git show-ref --verify --quiet "refs/remotes/origin/$branch"); then
        add_args=(--no-checkout "$mountpoint" -b "$branch" "origin/$branch")
    else
        add_args=(--no-checkout "$mountpoint" -b "$branch")
    fi

    if ! (cd "$repo" && git worktree add "${add_args[@]}"); then
        rm -rf "$session_dir"
        rmdir "$mountpoint" 2>/dev/null || true
        return 1
    fi

    if [[ -e "$mountpoint/.git" ]]; then
        mv "$mountpoint/.git" "$upper/.git"
    fi

    local tree_sha
    if ! tree_sha=$(resolve_tree_sha "$repo" "$branch"); then
        echo "Error: could not resolve tree SHA for branch '$branch'" >&2
        (cd "$repo" && git worktree remove --force "$mountpoint") 2>/dev/null || true
        rm -rf "$session_dir"
        return 1
    fi

    local ref_dir="$cache/ref/$tree_sha"
    if ! ensure_reference "$repo" "$branch" "$ref_dir"; then
        echo "Error: could not populate reference at $ref_dir" >&2
        (cd "$repo" && git worktree remove --force "$mountpoint") 2>/dev/null || true
        rm -rf "$session_dir"
        return 1
    fi

    if ! overlay_mount "$ref_dir" "$upper" "$workdir" "$mountpoint"; then
        echo "Error: overlay mount failed" >&2
        (cd "$repo" && git worktree remove --force "$mountpoint") 2>/dev/null || true
        rm -rf "$session_dir"
        return 1
    fi

    git -C "$mountpoint" config extensions.worktreeConfig true 2>/dev/null || true
    git -C "$mountpoint" config --worktree core.checkStat minimal 2>/dev/null \
        || git -C "$mountpoint" config core.checkStat minimal
    git -C "$mountpoint" config --worktree core.trustctime false 2>/dev/null \
        || git -C "$mountpoint" config core.trustctime false

    git -C "$mountpoint" update-index --refresh >/dev/null 2>&1 || true

    printf '%s\n' "$session_dir" > "$upper/.gh-wt-session"
}

session_dir_for_mountpoint() {
    local repo="$1" mountpoint="$2"
    local gitfile gitdir wtname cache
    gitfile="$mountpoint/.git"
    if [[ ! -f "$gitfile" ]]; then
        return 1
    fi
    gitdir=$(sed -n 's/^gitdir: //p' "$gitfile" | head -n1)
    [[ -z "$gitdir" ]] && return 1
    wtname=$(basename "$gitdir")
    cache=$(cache_dir_for_repo "$repo")
    printf '%s/sessions/%s\n' "$cache" "$wtname"
}

session_remove() {
    local repo="$1" mountpoint="$2"

    if overlay_has_processes "$mountpoint"; then
        echo "Error: processes are still using $mountpoint" >&2
        return 1
    fi

    local session_dir=""
    session_dir=$(session_dir_for_mountpoint "$repo" "$mountpoint" 2>/dev/null || true)

    if overlay_is_mounted "$mountpoint"; then
        if ! overlay_umount "$mountpoint"; then
            echo "Error: failed to unmount $mountpoint" >&2
            return 1
        fi
    fi

    (cd "$repo" && git worktree remove --force "$mountpoint") || true

    if [[ -n "$session_dir" && -d "$session_dir" ]]; then
        rm -rf "$session_dir"
    fi
}

session_gc() {
    local repo="$1"
    local cache ref_root
    cache=$(cache_dir_for_repo "$repo")
    ref_root="$cache/ref"
    [[ -d "$ref_root" ]] || { echo "gc: no references to consider"; return 0; }

    local active
    active=$(overlay_active_lowers)

    local removed=0 kept=0 ref
    for ref in "$ref_root"/*; do
        [[ -d "$ref" ]] || continue
        if printf '%s\n' "$active" | grep -Fxq -- "$ref"; then
            kept=$((kept + 1))
            continue
        fi
        rm -rf "$ref"
        echo "removed: $ref"
        removed=$((removed + 1))
    done
    echo "gc: removed $removed reference(s), kept $kept"
}

session_doctor() {
    local ok=0
    echo "Platform: $(uname -s) $(uname -r)"

    if overlay_precheck 2>/dev/null; then
        echo "overlay: available"
    else
        overlay_precheck
        ok=1
    fi

    if git rev-parse --git-common-dir >/dev/null 2>&1; then
        local repo
        repo=$(require_main_repo)
        echo "repo:     $repo"
        echo "cache:    $(cache_dir_for_repo "$repo")"
        if [[ -f "$repo/.gitmodules" ]]; then
            echo "warning:  repository has submodules (not supported in v0)"
            ok=1
        fi
    else
        echo "repo:     (not inside a git repository)"
    fi

    if [[ "$(uname -s)" == "Linux" ]]; then
        if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
            echo "warning:  mount(2) typically requires CAP_SYS_ADMIN / root"
        fi
    fi

    return $ok
}
