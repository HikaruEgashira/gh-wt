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

check_repo_sanity() {
    local repo="$1"
    local is_bare
    is_bare=$(git -C "$repo" rev-parse --is-bare-repository 2>/dev/null) \
        || die "not inside a git repository"
    [[ "$is_bare" == "false" ]] || die "bare repositories are not supported"
    [[ ! -f "$repo/.gitmodules" ]] \
        || die "repositories with submodules are not supported in v0"
}

have_mount_cap() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    command -v sudo >/dev/null 2>&1 || return 1
    sudo -n true 2>/dev/null
}

require_env() {
    [[ "$(uname -s)" == "Linux" ]] || die "Linux only (this is v0)"
    check_kernel
    check_overlay_fs
    have_mount_cap || die "mount requires root or passwordless sudo"
}

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}
