#!/usr/bin/env bash

overlay_mount() {
    local lower="$1" upper="$2" work="$3" mountpoint="$4"
    run_as_root mount -t overlay overlay \
        -o "lowerdir=$lower,upperdir=$upper,workdir=$work" \
        "$mountpoint"
}

overlay_umount() {
    local mountpoint="$1"
    run_as_root umount "$mountpoint"
}

is_mounted() {
    local mountpoint="$1"
    mountpoint -q "$mountpoint" 2>/dev/null
}

live_overlay_lowerdirs() {
    awk '$3 == "overlay" { print $4 }' /proc/mounts \
        | tr ',' '\n' \
        | sed -n 's/^lowerdir=//p'
}

check_mountpoint_free() {
    local mountpoint="$1"
    command -v fuser >/dev/null 2>&1 || return 0
    if fuser -m "$mountpoint" >/dev/null 2>&1; then
        die "processes still using $mountpoint"
    fi
}
