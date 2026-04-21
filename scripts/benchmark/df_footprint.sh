#!/usr/bin/env bash
# Measure real physical bytes consumed (via df delta) for N worktrees
# created by (a) git worktree add and (b) gh-wt APFS clonefile.
# du on APFS does NOT reflect clonefile sharing; df does.
set -euo pipefail
ROOT="/private/tmp/ghwt-bench"
REPO="$ROOT/linux"
GH_WT="${GH_WT:-$(cd "$(dirname "$0")/../.." && pwd)/gh-wt}"
export GH_WT_CACHE="$ROOT/cache"
OUT="$ROOT/results/df_footprint.tsv"
: > "$OUT"
printf 'method\twt_count\tdf_delta_kb\n' >> "$OUT"

df_used_kb() { df -k "$HOME" | awk 'NR==2 {print $3}'; }

# CLEAR everything first
for d in "$ROOT"/wt-fp-base-* "$ROOT"/wt-fp-ghwt-*; do
    [[ -d "$d" ]] && (git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d")
done
rm -rf "$GH_WT_CACHE"
git -C "$REPO" worktree prune >/dev/null 2>&1
sync

# --- baseline ---
for k in 1 3 5; do
    for d in "$ROOT"/wt-fp-base-*; do [[ -d "$d" ]] && (git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"); done
    git -C "$REPO" worktree prune >/dev/null 2>&1
    sync; sleep 2
    local_before=$(df_used_kb)
    for j in $(seq 0 $((k-1))); do
        git -C "$REPO" worktree add --force "$ROOT/wt-fp-base-$j" "bench-$j" >/dev/null
    done
    sync; sleep 2
    local_after=$(df_used_kb)
    printf 'baseline\t%d\t%d\n' "$k" $((local_after - local_before)) >> "$OUT"
done

# cleanup baseline
for d in "$ROOT"/wt-fp-base-*; do [[ -d "$d" ]] && (git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"); done
git -C "$REPO" worktree prune >/dev/null 2>&1
rm -rf "$GH_WT_CACHE"
sync; sleep 2

# --- gh-wt APFS ---
# Separate measurement: first run includes reference cache build cost.
for k in 1 3 5; do
    for d in "$ROOT"/wt-fp-ghwt-*; do [[ -d "$d" ]] && (git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"); done
    rm -rf "$GH_WT_CACHE"
    git -C "$REPO" worktree prune >/dev/null 2>&1
    sync; sleep 2
    local_before=$(df_used_kb)
    for j in $(seq 0 $((k-1))); do
        (cd "$REPO" && "$GH_WT" add "bench-$j" "$ROOT/wt-fp-ghwt-$j" >/dev/null)
    done
    sync; sleep 2
    local_after=$(df_used_kb)
    printf 'gh-wt-apfs\t%d\t%d\n' "$k" $((local_after - local_before)) >> "$OUT"
done

# cleanup
for d in "$ROOT"/wt-fp-ghwt-*; do [[ -d "$d" ]] && (git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"); done
rm -rf "$GH_WT_CACHE"
git -C "$REPO" worktree prune >/dev/null 2>&1

echo "== df footprint =="
cat "$OUT"
