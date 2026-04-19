#!/usr/bin/env bash

overlay_mount() {
    local lower="$1" upper="$2" work="$3" mountpoint="$4"
    case "$(uname -s)" in
        Linux)
            run_as_root mount -t overlay overlay \
                -o "lowerdir=$lower,upperdir=$upper,workdir=$work" \
                "$mountpoint"
            ;;
        Darwin)
            gh-wt-mount-overlay mount \
                --lower "$lower" \
                --upper "$upper" \
                --mountpoint "$mountpoint"
            ;;
        *) die "unsupported platform: $(uname -s)" ;;
    esac
}

overlay_umount() {
    local mountpoint="$1"
    case "$(uname -s)" in
        Linux)  run_as_root umount "$mountpoint" ;;
        Darwin) gh-wt-mount-overlay unmount --mountpoint "$mountpoint" ;;
        *) die "unsupported platform: $(uname -s)" ;;
    esac
}

is_mounted() {
    local mountpoint="$1"
    case "$(uname -s)" in
        Linux)
            mountpoint -q "$mountpoint" 2>/dev/null
            ;;
        Darwin)
            # On macOS, /sbin/mount lists mounted filesystems; match by path.
            /sbin/mount | awk -v p="$mountpoint" '$3 == p { found=1 } END { exit !found }'
            ;;
        *) return 1 ;;
    esac
}

live_overlay_lowerdirs() {
    case "$(uname -s)" in
        Linux)
            awk '$3 == "overlay" { print $4 }' /proc/mounts \
                | tr ',' '\n' \
                | sed -n 's/^lowerdir=//p' \
                | while IFS= read -r lower; do
                    printf '%b\n' "$lower"
                done
            ;;
        Darwin)
            # The helper records each live mount's lower dir under
            # ~/Library/Application Support/gh-wt-overlay/mounts/<hash>.
            gh-wt-mount-overlay list-lowers 2>/dev/null || true
            ;;
        *) ;;
    esac
}

check_mountpoint_free() {
    local mountpoint="$1"
    case "$(uname -s)" in
        Linux)
            command -v fuser >/dev/null 2>&1 || return 0
            if fuser -m "$mountpoint" >/dev/null 2>&1; then
                die "processes still using $mountpoint"
            fi
            ;;
        Darwin)
            command -v lsof >/dev/null 2>&1 || return 0
            if lsof +D "$mountpoint" >/dev/null 2>&1; then
                die "processes still using $mountpoint"
            fi
            ;;
        *) ;;
    esac
}
