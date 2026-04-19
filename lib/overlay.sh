#!/usr/bin/env bash

overlay_precheck() {
    case "$(uname -s)" in
        Linux)
            if [[ ! -r /proc/filesystems ]]; then
                echo "Error: /proc/filesystems not readable" >&2
                return 1
            fi
            if ! awk '{print $NF}' /proc/filesystems | grep -qx overlay; then
                echo "Error: OverlayFS not available in this kernel" >&2
                return 1
            fi
            ;;
        Darwin)
            if ! command -v gh-wt-mount-overlay >/dev/null 2>&1; then
                echo "Error: gh-wt-mount-overlay helper not found." >&2
                echo "       Install gh-wt-overlay.app and enable the FSKit" >&2
                echo "       extension under System Settings > Login Items and" >&2
                echo "       Extensions > File System Extensions." >&2
                return 1
            fi
            ;;
        *)
            echo "Error: unsupported platform $(uname -s)" >&2
            return 1
            ;;
    esac
}

overlay_mount() {
    local lower="$1" upper="$2" workdir="$3" mountpoint="$4"
    case "$(uname -s)" in
        Linux)
            mount -t overlay overlay \
                -o "lowerdir=$lower,upperdir=$upper,workdir=$workdir" \
                "$mountpoint"
            ;;
        Darwin)
            gh-wt-mount-overlay \
                --lower "$lower" --upper "$upper" --mountpoint "$mountpoint"
            ;;
        *)
            echo "Error: unsupported platform" >&2
            return 1
            ;;
    esac
}

overlay_umount() {
    local mountpoint="$1"
    case "$(uname -s)" in
        Linux)  umount "$mountpoint" ;;
        Darwin) gh-wt-mount-overlay --unmount "$mountpoint" ;;
        *)
            echo "Error: unsupported platform" >&2
            return 1
            ;;
    esac
}

overlay_is_mounted() {
    local mountpoint="$1"
    case "$(uname -s)" in
        Linux)
            mountpoint -q "$mountpoint" 2>/dev/null
            ;;
        Darwin)
            /sbin/mount | awk '{print $3}' | grep -qx "$mountpoint"
            ;;
        *) return 1 ;;
    esac
}

overlay_active_lowers() {
    case "$(uname -s)" in
        Linux)
            [[ -r /proc/self/mountinfo ]] || return 0
            awk '$9 == "overlay" {print $0}' /proc/self/mountinfo \
                | sed -n 's/.*lowerdir=\([^,]*\).*/\1/p'
            ;;
        Darwin)
            gh-wt-mount-overlay --list-lowers 2>/dev/null || true
            ;;
    esac
}

overlay_has_processes() {
    local mountpoint="$1"
    if command -v fuser >/dev/null 2>&1; then
        fuser -m "$mountpoint" >/dev/null 2>&1
        return $?
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof +D "$mountpoint" >/dev/null 2>&1
        return $?
    fi
    return 1
}
