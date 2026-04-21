#!/usr/bin/env bash
# Extended same-tree scaling: N worktrees at HEAD commit, varying k.
# Empirical validation of the O(1) scaling claim in §2.3.1.
set -euo pipefail
ROOT="/private/tmp/ghwt-bench"
REPO="$ROOT/linux"
GH_WT="${GH_WT:-$(cd "$(dirname "$0")/../.." && pwd)/gh-wt}"
export GH_WT_CACHE="$ROOT/cache"
OUT="$ROOT/results/scaling.tsv"
mkdir -p "$ROOT/results"
: > "$OUT"
printf 'method\twt_count\tdf_delta_kb\n' >> "$OUT"

df_used_kb() { df -k "$HOME" | awk 'NR==2 {print $3}'; }

# k values; baseline is O(N) so capped to keep disk <30GB; gh-wt O(1) so reach higher
K_BASELINE=(1 2 5 10)
K_GHWT=(1 2 5 10 15 20)
MAX_K=20
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

# Prep branches
for i in $(seq 0 $((MAX_K - 1))); do
    git -C "$REPO" branch -D "sw-$i" >/dev/null 2>&1 || true
    git -C "$REPO" branch "sw-$i" "$HEAD_SHA"
done

cleanup_all() {
    for d in "$ROOT"/wt-sw-*; do [[ -d "$d" ]] && (git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"); done
    rm -rf "$GH_WT_CACHE"
    git -C "$REPO" worktree prune >/dev/null 2>&1
}

# Baseline
for k in "${K_BASELINE[@]}"; do
    cleanup_all; sync; sleep 2
    before=$(df_used_kb)
    for j in $(seq 0 $((k-1))); do
        git -C "$REPO" worktree add --force "$ROOT/wt-sw-base-$j" "sw-$j" >/dev/null
    done
    sync; sleep 2
    after=$(df_used_kb)
    printf 'baseline\t%d\t%d\n' "$k" $((after - before)) >> "$OUT"
    echo "  baseline k=$k: $((after - before)) KiB"
    cleanup_all; sync; sleep 1
done

# gh-wt APFS
for k in "${K_GHWT[@]}"; do
    cleanup_all; sync; sleep 2
    before=$(df_used_kb)
    for j in $(seq 0 $((k-1))); do
        (cd "$REPO" && "$GH_WT" add "sw-$j" "$ROOT/wt-sw-ghwt-$j" >/dev/null)
    done
    sync; sleep 2
    after=$(df_used_kb)
    printf 'gh-wt-apfs\t%d\t%d\n' "$k" $((after - before)) >> "$OUT"
    echo "  gh-wt    k=$k: $((after - before)) KiB"
    cleanup_all; sync; sleep 1
done

# Cleanup branches
for i in $(seq 0 $((MAX_K - 1))); do git -C "$REPO" branch -D "sw-$i" >/dev/null 2>&1 || true; done

echo "== scaling =="
cat "$OUT"
