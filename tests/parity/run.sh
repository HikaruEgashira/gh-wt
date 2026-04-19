#!/usr/bin/env bash
# tests/parity/run.sh — overlay semantics parity harness.
#
# Runs each script under tests/parity/cases/ against a freshly-mounted
# overlay. The harness is platform-agnostic: it picks up the right backend
# from $(uname -s) and gives the test case access to:
#
#   $LOWER       absolute path to the (read-only) lower dir
#   $UPPER       absolute path to the writable upper dir
#   $MNT         absolute path where the overlay is mounted
#   assert_eq    helper that diffs expected vs actual
#
# Each case writes its expectations against the *user-visible mountpoint*,
# which is the contract this overlay must honour identically on Linux
# OverlayFS and the macOS FSKit implementation.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CASES_DIR="$HERE/cases"

case "$(uname -s)" in
    Linux)
        BACKEND=overlayfs
        ;;
    Darwin)
        BACKEND=fskit
        ;;
    *)
        echo "unsupported platform: $(uname -s)" >&2
        exit 2
        ;;
esac

MOUNT_BACKEND="$BACKEND"
if [[ "${1:-}" == "--backend" ]]; then
    MOUNT_BACKEND="$2"
    shift 2
fi

# Accept both legacy (linux|darwin) and explicit (overlayfs|fskit|macfuse)
# names so existing CI invocations keep working.
case "$MOUNT_BACKEND" in
    linux)  MOUNT_BACKEND=overlayfs ;;
    darwin) MOUNT_BACKEND=fskit ;;
esac

case "$MOUNT_BACKEND" in
    overlayfs) ;;
    fskit)
        command -v gh-wt-mount-overlay >/dev/null \
            || { echo "gh-wt-mount-overlay not in PATH" >&2; exit 2; }
        ;;
    macfuse)
        command -v gh-wt-mount-overlay-fuse >/dev/null \
            || { echo "gh-wt-mount-overlay-fuse not in PATH" >&2; exit 2; }
        ;;
    *)
        echo "unknown --backend: $MOUNT_BACKEND (expected overlayfs|fskit|macfuse)" >&2
        exit 2
        ;;
esac

mount_overlay() {
    case "$MOUNT_BACKEND" in
        overlayfs)
            sudo mount -t overlay overlay \
                -o "lowerdir=$LOWER,upperdir=$UPPER,workdir=$WORK" \
                "$MNT"
            ;;
        fskit)
            gh-wt-mount-overlay mount --backend fskit \
                --lower "$LOWER" --upper "$UPPER" --mountpoint "$MNT"
            ;;
        macfuse)
            gh-wt-mount-overlay-fuse mount \
                --lower "$LOWER" --upper "$UPPER" --mountpoint "$MNT"
            ;;
    esac
}

umount_overlay() {
    case "$MOUNT_BACKEND" in
        overlayfs) sudo umount "$MNT" || true ;;
        fskit)     gh-wt-mount-overlay --backend fskit unmount --mountpoint "$MNT" || true ;;
        macfuse)   gh-wt-mount-overlay-fuse unmount --mountpoint "$MNT" || true ;;
    esac
}

setup_layers() {
    local tmp="${TMPDIR:-/tmp}"
    LOWER=$(mktemp -d "$tmp/ghwt-lower.XXXXXX")
    UPPER=$(mktemp -d "$tmp/ghwt-upper.XXXXXX")
    WORK=$(mktemp -d "$tmp/ghwt-work.XXXXXX")
    MNT=$(mktemp -d "$tmp/ghwt-mnt.XXXXXX")
    export LOWER UPPER WORK MNT
}

teardown_layers() {
    umount_overlay
    rm -rf "$LOWER" "$UPPER" "$WORK" "$MNT" 2>/dev/null || true
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf "FAIL: %s\n  expected: %q\n  actual:   %q\n" "$label" "$expected" "$actual" >&2
        return 1
    fi
}
export -f assert_eq

assert_file_eq() {
    local label="$1" expected="$2" actual="$3"
    if ! diff -q "$expected" "$actual" >/dev/null 2>&1; then
        printf "FAIL: %s\n" "$label" >&2
        diff "$expected" "$actual" | head -40 >&2
        return 1
    fi
}
export -f assert_file_eq

run_case() {
    local case_path="$1"
    local case_name
    case_name=$(basename "$case_path" .sh)

    setup_layers

    # Each case has two phases:
    #   - a "fixture" function that populates LOWER (run before mount)
    #   - a "verify" function that operates on $MNT (run after mount)
    # shellcheck source=/dev/null
    source "$case_path"
    type fixture >/dev/null && fixture
    mount_overlay
    if verify; then
        printf "PASS: %s (%s)\n" "$case_name" "$MOUNT_BACKEND"
        teardown_layers
        return 0
    else
        printf "FAIL: %s (%s)\n" "$case_name" "$MOUNT_BACKEND" >&2
        teardown_layers
        return 1
    fi
}

failed=0
total=0
for case_path in "$CASES_DIR"/*.sh; do
    total=$((total + 1))
    if [[ "$#" -gt 0 ]]; then
        case "$(basename "$case_path" .sh)" in
            "$1") ;;
            *) continue ;;
        esac
    fi
    if ! ( run_case "$case_path" ); then
        failed=$((failed + 1))
    fi
    # Reset case-defined functions between iterations.
    unset -f fixture verify 2>/dev/null || true
done

echo
echo "summary: $((total - failed)) / $total passed (backend=$MOUNT_BACKEND)"
[[ "$failed" -eq 0 ]]
