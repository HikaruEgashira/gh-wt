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
ROOT="$(cd "$HERE/../.." && pwd)"
CASES_DIR="$HERE/cases"

case "$(uname -s)" in
    Linux)
        BACKEND=linux
        ;;
    Darwin)
        BACKEND=darwin
        command -v gh-wt-mount-overlay >/dev/null \
            || { echo "gh-wt-mount-overlay not in PATH" >&2; exit 2; }
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

mount_overlay() {
    case "$MOUNT_BACKEND" in
        linux)
            sudo mount -t overlay overlay \
                -o "lowerdir=$LOWER,upperdir=$UPPER,workdir=$WORK" \
                "$MNT"
            ;;
        darwin)
            gh-wt-mount-overlay mount \
                --lower "$LOWER" --upper "$UPPER" --mountpoint "$MNT"
            ;;
    esac
}

umount_overlay() {
    case "$MOUNT_BACKEND" in
        linux)  sudo umount "$MNT" || true ;;
        darwin) gh-wt-mount-overlay unmount --mountpoint "$MNT" || true ;;
    esac
}

setup_layers() {
    LOWER=$(mktemp -d -t ghwt-lower)
    UPPER=$(mktemp -d -t ghwt-upper)
    WORK=$(mktemp -d -t ghwt-work)
    MNT=$(mktemp -d -t ghwt-mnt)
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
