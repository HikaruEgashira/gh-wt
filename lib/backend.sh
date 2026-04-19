#!/usr/bin/env bash

# Backend resolution. GH_WT_BACKEND picks one of:
#   auto       — pick the best available for this platform (default)
#   overlayfs  — Linux kernel OverlayFS
#   fskit      — macOS 26+ FSKit System Extension (via gh-wt-mount-overlay)
#   macfuse    — macOS with macFUSE (via gh-wt-mount-overlay-fuse)
#
# Resolution is memoised in GH_WT_RESOLVED_BACKEND for the life of the process
# so sub-shells and repeated calls don't redo detection.

backend_is_known() {
    case "$1" in
        overlayfs|fskit|macfuse) return 0 ;;
        *) return 1 ;;
    esac
}

fskit_helper_available() {
    command -v gh-wt-mount-overlay >/dev/null 2>&1
}

macfuse_helper_available() {
    command -v gh-wt-mount-overlay-fuse >/dev/null 2>&1
}

macfuse_kext_available() {
    # macFUSE ships a filesystem bundle; presence of the FS type is the
    # cheapest availability check that doesn't require loading anything.
    [[ -d /Library/Filesystems/macfuse.fs ]] \
        || [[ -d /Library/Filesystems/osxfuse.fs ]]
}

macos_major_version() {
    local product major
    product=$(sw_vers -productVersion 2>/dev/null) || return 1
    major="${product%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    echo "$major"
}

auto_select_backend() {
    case "$(uname -s)" in
        Linux)
            echo overlayfs
            ;;
        Darwin)
            local major
            major=$(macos_major_version 2>/dev/null || echo 0)
            if (( major >= 26 )) && fskit_helper_available; then
                echo fskit
            elif macfuse_helper_available; then
                echo macfuse
            elif (( major >= 26 )); then
                # fskit is the only option but the helper is missing — still
                # report it so doctor can explain exactly what's wrong.
                echo fskit
            else
                echo macfuse
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# Emit the effective backend for this process. Honours GH_WT_BACKEND, falls
# back to auto. Exports GH_WT_RESOLVED_BACKEND so subsequent calls are O(1).
resolve_backend() {
    if [[ -n "${GH_WT_RESOLVED_BACKEND:-}" ]]; then
        echo "$GH_WT_RESOLVED_BACKEND"
        return 0
    fi

    local requested="${GH_WT_BACKEND:-auto}"
    local resolved
    case "$requested" in
        auto)
            resolved=$(auto_select_backend) \
                || die "unsupported platform: $(uname -s)"
            ;;
        overlayfs|fskit|macfuse)
            resolved="$requested"
            ;;
        *)
            die "unknown GH_WT_BACKEND: $requested (expected auto|overlayfs|fskit|macfuse)"
            ;;
    esac

    # Sanity-check that the requested backend fits the host OS. This catches
    # misconfiguration early (e.g. overlayfs on Darwin) rather than failing
    # at mount time with an opaque error.
    case "$resolved" in
        overlayfs)
            [[ "$(uname -s)" == "Linux" ]] \
                || die "overlayfs backend requires Linux (host is $(uname -s))"
            ;;
        fskit|macfuse)
            [[ "$(uname -s)" == "Darwin" ]] \
                || die "$resolved backend requires Darwin (host is $(uname -s))"
            ;;
    esac

    export GH_WT_RESOLVED_BACKEND="$resolved"
    echo "$resolved"
}
