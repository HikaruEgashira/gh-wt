#!/usr/bin/env bash

die() {
    echo "gh-wt: $*" >&2
    exit 1
}

# Portable `readlink -m`: canonicalise a path whether it exists or not.
# GNU readlink supports -m; BSD (macOS) does not. We resolve the nearest
# existing ancestor with `cd ... && pwd -P`, then append the remainder.
canonical_path() {
    local input="$1"
    [[ -n "$input" ]] || return 1
    [[ "$input" == /* ]] || input="$PWD/$input"

    local head="$input" tail=""
    while [[ ! -d "$head" ]]; do
        local base
        base=$(basename "$head")
        tail="$base${tail:+/$tail}"
        local parent
        parent=$(dirname "$head")
        [[ "$parent" == "$head" ]] && break
        head="$parent"
    done

    local resolved_head
    resolved_head=$(cd "$head" 2>/dev/null && pwd -P) || resolved_head="$head"
    if [[ -z "$tail" ]]; then
        echo "$resolved_head"
    elif [[ "$resolved_head" == "/" ]]; then
        echo "/$tail"
    else
        echo "$resolved_head/$tail"
    fi
}

check_kernel() {
    local release major minor
    release=$(uname -r)
    major="${release%%.*}"
    minor="${release#*.}"
    minor="${minor%%.*}"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || die "cannot parse kernel version: $release"
    if (( major < 5 )) || (( major == 5 && minor < 11 )); then
        die "Linux kernel 5.11+ required (found $release)"
    fi
}

check_overlay_fs() {
    grep -qw overlay /proc/filesystems 2>/dev/null \
        || die "OverlayFS not available (no 'overlay' in /proc/filesystems)"
}

check_repo_sanity() {
    local repo="$1"
    local is_bare
    is_bare=$(git -C "$repo" rev-parse --is-bare-repository 2>/dev/null) \
        || die "not inside a git repository"
    [[ "$is_bare" == "false" ]] || die "bare repositories are not supported"
}

check_branch_no_submodules() {
    local repo="$1" rev="$2"
    if git -C "$repo" cat-file -e "$rev:.gitmodules" 2>/dev/null; then
        die "repositories with submodules are not supported in v0"
    fi
}

have_mount_cap() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    command -v sudo >/dev/null 2>&1 || return 1
    sudo -n true 2>/dev/null
}

require_env() {
    local backend
    backend=$(resolve_backend)
    case "$backend" in
        overlayfs)
            check_kernel
            check_overlay_fs
            have_mount_cap || die "mount requires root or passwordless sudo"
            ;;
        apfs)
            apfs_clone_available \
                || die "APFS clonefile(2) not supported here — cache/worktree must live on an APFS volume"
            ;;
        none)
            # Plain git worktree; no external dependency to check.
            ;;
        *)
            die "unresolved backend: $backend"
            ;;
    esac
}

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Remove a session dir. OverlayFS upper is owned by root because mount runs
# as root; the macOS backends run in the user's session and the upper is
# user-owned, so plain rm is correct there.
remove_session_dir() {
    local sdir="$1"
    case "$(resolve_backend)" in
        overlayfs) run_as_root rm -rf "$sdir" ;;
        *)         rm -rf "$sdir" ;;
    esac
}

# Same rationale for cache references (built by `git archive | tar` as the
# user on both platforms, so root is only needed if Linux later wrote into
# the ref via overlay copy-up — which it shouldn't, but be defensive).
remove_cache_path() {
    local path="$1"
    case "$(resolve_backend)" in
        overlayfs) run_as_root rm -rf "$path" ;;
        *)         rm -rf "$path" ;;
    esac
}
