#!/usr/bin/env bash

die() {
    echo "gh-wt: $*" >&2
    exit 1
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

check_macos_version() {
    local product major
    product=$(sw_vers -productVersion 2>/dev/null) \
        || die "cannot determine macOS version"
    major="${product%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] || die "cannot parse macOS version: $product"
    (( major >= 26 )) || die "macOS 26+ required for FSKit overlay (found $product)"
}

check_fskit_helper() {
    command -v gh-wt-mount-overlay >/dev/null 2>&1 \
        || die "gh-wt-mount-overlay helper not in PATH (see docs/distribution.md for install instructions)"
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
    case "$(uname -s)" in
        Linux)
            check_kernel
            check_overlay_fs
            have_mount_cap || die "mount requires root or passwordless sudo"
            ;;
        Darwin)
            check_macos_version
            check_fskit_helper
            ;;
        *)
            die "unsupported platform: $(uname -s)"
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

# Remove a session dir. On Linux, OverlayFS upper is owned by root because
# mount runs as root; on Darwin, FSKit runs in the user's session and the
# upper is user-owned, so plain rm is correct.
remove_session_dir() {
    local sdir="$1"
    case "$(uname -s)" in
        Linux)  run_as_root rm -rf "$sdir" ;;
        *)      rm -rf "$sdir" ;;
    esac
}

# Same rationale for cache references (built by `git archive | tar` as the
# user on both platforms, so root is only needed if Linux later wrote into
# the ref via overlay copy-up — which it shouldn't, but be defensive).
remove_cache_path() {
    local path="$1"
    case "$(uname -s)" in
        Linux)  run_as_root rm -rf "$path" ;;
        *)      rm -rf "$path" ;;
    esac
}
