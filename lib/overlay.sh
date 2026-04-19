#!/usr/bin/env bash

# Backend dispatch. resolve_backend (lib/backend.sh) decides which of
# overlayfs / fskit / macfuse we talk to; this file forwards mount/unmount/
# inspection calls to the right helper.

overlay_mount() {
    local lower="$1" upper="$2" work="$3" mountpoint="$4"
    case "$(resolve_backend)" in
        overlayfs)
            run_as_root mount -t overlay overlay \
                -o "lowerdir=$lower,upperdir=$upper,workdir=$work" \
                "$mountpoint"
            ;;
        fskit)
            gh-wt-mount-overlay mount \
                --backend fskit \
                --lower "$lower" \
                --upper "$upper" \
                --mountpoint "$mountpoint"
            ;;
        macfuse)
            gh-wt-mount-overlay-fuse mount \
                --lower "$lower" \
                --upper "$upper" \
                --mountpoint "$mountpoint"
            ;;
    esac
}

overlay_umount() {
    local mountpoint="$1"
    case "$(resolve_backend)" in
        overlayfs) run_as_root umount "$mountpoint" ;;
        fskit)     gh-wt-mount-overlay --backend fskit unmount --mountpoint "$mountpoint" ;;
        macfuse)   gh-wt-mount-overlay-fuse unmount --mountpoint "$mountpoint" ;;
    esac
}

is_mounted() {
    local mountpoint="$1"
    case "$(resolve_backend)" in
        overlayfs)
            mountpoint -q "$mountpoint" 2>/dev/null
            ;;
        fskit|macfuse)
            # Both macOS backends appear in /sbin/mount; match by target path.
            /sbin/mount | awk -v p="$mountpoint" '$3 == p { found=1 } END { exit !found }'
            ;;
    esac
}

live_overlay_lowerdirs() {
    case "$(resolve_backend)" in
        overlayfs)
            awk '$3 == "overlay" { print $4 }' /proc/mounts \
                | tr ',' '\n' \
                | sed -n 's/^lowerdir=//p' \
                | while IFS= read -r lower; do
                    printf '%b\n' "$lower"
                done
            ;;
        fskit)
            # Helper records each live mount's lower dir under
            # ~/Library/Application Support/gh-wt-overlay/mounts/<hash>.
            gh-wt-mount-overlay list-lowers 2>/dev/null || true
            ;;
        macfuse)
            gh-wt-mount-overlay-fuse list-lowers 2>/dev/null || true
            ;;
    esac
}

check_mountpoint_free() {
    local mountpoint="$1"
    case "$(resolve_backend)" in
        overlayfs)
            command -v fuser >/dev/null 2>&1 || return 0
            if fuser -m "$mountpoint" >/dev/null 2>&1; then
                die "processes still using $mountpoint"
            fi
            ;;
        fskit|macfuse)
            command -v lsof >/dev/null 2>&1 || return 0
            if lsof +D "$mountpoint" >/dev/null 2>&1; then
                die "processes still using $mountpoint"
            fi
            ;;
    esac
}
