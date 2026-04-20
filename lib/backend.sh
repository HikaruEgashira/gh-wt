#!/usr/bin/env bash

# Platform auto-detection. `gh-wt` exposes no knob for this — the best
# available mode for the host is picked and memoised in GH_WT_RESOLVED_BACKEND
# for the life of the process so sub-shells don't redo detection.
#
#   Linux   → overlayfs  (kernel 5.11+; needs root / passwordless sudo)
#   macOS   → apfs       (clonefile(2) CoW, helper-free) or
#             none       (non-APFS volume fallback)
#   other   → none

# APFS clonefile(2) via `cp -c`. Memoised via GH_WT_APFS_CLONE.
apfs_clone_available() {
    if [[ -n "${GH_WT_APFS_CLONE:-}" ]]; then
        [[ "$GH_WT_APFS_CLONE" == 1 ]]
        return
    fi
    local dir
    dir=$(mktemp -d 2>/dev/null) || { export GH_WT_APFS_CLONE=0; return 1; }
    : > "$dir/src"
    if cp -c "$dir/src" "$dir/dst" 2>/dev/null; then
        export GH_WT_APFS_CLONE=1
        rm -rf "$dir"
        return 0
    fi
    export GH_WT_APFS_CLONE=0
    rm -rf "$dir"
    return 1
}

resolve_backend() {
    if [[ -n "${GH_WT_RESOLVED_BACKEND:-}" ]]; then
        echo "$GH_WT_RESOLVED_BACKEND"
        return 0
    fi
    local resolved
    case "$(uname -s)" in
        Linux)
            resolved=overlayfs
            ;;
        Darwin)
            if apfs_clone_available; then
                resolved=apfs
            else
                resolved=none
            fi
            ;;
        *)
            resolved=none
            ;;
    esac
    export GH_WT_RESOLVED_BACKEND="$resolved"
    echo "$resolved"
}
