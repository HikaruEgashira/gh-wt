#!/usr/bin/env bash
# tests/parity/run.sh — OverlayFS semantics parity harness.
#
# Runs each script under tests/parity/cases/ against a freshly-mounted
# OverlayFS. Only Linux is supported; macOS uses APFS clonefile which
# has different semantics (no lower/upper layering) and is exercised
# by smoke tests instead.
#
# Each case writes its expectations against the *user-visible mountpoint*,
# and has access to:
#
#   $LOWER       absolute path to the (read-only) lower dir
#   $UPPER       absolute path to the writable upper dir
#   $MNT         absolute path where the overlay is mounted
#   assert_eq    helper that diffs expected vs actual

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CASES_DIR="$HERE/cases"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "parity suite only runs on Linux (OverlayFS)" >&2
    exit 2
fi

mount_overlay() {
    sudo mount -t overlay overlay \
        -o "lowerdir=$LOWER,upperdir=$UPPER,workdir=$WORK" \
        "$MNT"
}

umount_overlay() {
    sudo umount "$MNT" || true
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
        printf "PASS: %s\n" "$case_name"
        teardown_layers
        return 0
    else
        printf "FAIL: %s\n" "$case_name" >&2
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
echo "summary: $((total - failed)) / $total passed"
[[ "$failed" -eq 0 ]]
