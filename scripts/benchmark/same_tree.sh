#!/usr/bin/env bash
# Same-tree scenario: N branches at the SAME commit (tree SHA identical).
# This is the best case for gh-wt: the reference is built once and all
# clonefile-copies share blocks with it.
set -euo pipefail
ROOT="/private/tmp/ghwt-bench"
REPO="$ROOT/linux"
GH_WT="${GH_WT:-$(cd "$(dirname "$0")/../.." && pwd)/gh-wt}"
export GH_WT_CACHE="$ROOT/cache"
OUT="$ROOT/results/same_tree.tsv"
: > "$OUT"
printf 'method\twt_count\tdf_delta_kb\n' >> "$OUT"

df_used_kb() { df -k "$HOME" | awk 'NR==2 {print $3}'; }

# create same-tree branches: alt-0..alt-4 all at HEAD
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
for i in 0 1 2 3 4; do
    git -C "$REPO" branch -D "alt-$i" >/dev/null 2>&1 || true
    git -C "$REPO" branch "alt-$i" "$HEAD_SHA"
done

# cleanup
for d in "$ROOT"/wt-st-*; do [[ -d "$d" ]] && (git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"); done
rm -rf "$GH_WT_CACHE"
git -C "$REPO" worktree prune >/dev/null 2>&1

# baseline — 5 worktrees of 5 same-tree branches
for k in 1 3 5; do
    for d in "$ROOT"/wt-st-base-*; do [[ -d "$d" ]] && (git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"); done
    git -C "$REPO" worktree prune >/dev/null 2>&1
    sync; sleep 2
    before=$(df_used_kb)
    for j in $(seq 0 $((k-1))); do
        git -C "$REPO" worktree add --force "$ROOT/wt-st-base-$j" "alt-$j" >/dev/null
    done
    sync; sleep 2
    after=$(df_used_kb)
    printf 'baseline\t%d\t%d\n' "$k" $((after - before)) >> "$OUT"
done

for d in "$ROOT"/wt-st-base-*; do [[ -d "$d" ]] && (git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"); done
git -C "$REPO" worktree prune >/dev/null 2>&1
sync; sleep 2

# gh-wt — 5 worktrees of 5 same-tree branches share ONE reference
for k in 1 3 5; do
    for d in "$ROOT"/wt-st-ghwt-*; do [[ -d "$d" ]] && (git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"); done
    rm -rf "$GH_WT_CACHE"
    git -C "$REPO" worktree prune >/dev/null 2>&1
    sync; sleep 2
    before=$(df_used_kb)
    for j in $(seq 0 $((k-1))); do
        (cd "$REPO" && "$GH_WT" add "alt-$j" "$ROOT/wt-st-ghwt-$j" >/dev/null)
    done
    sync; sleep 2
    after=$(df_used_kb)
    printf 'gh-wt-apfs\t%d\t%d\n' "$k" $((after - before)) >> "$OUT"
done

for d in "$ROOT"/wt-st-ghwt-*; do [[ -d "$d" ]] && (git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"); done
rm -rf "$GH_WT_CACHE"
git -C "$REPO" worktree prune >/dev/null 2>&1
for i in 0 1 2 3 4; do git -C "$REPO" branch -D "alt-$i" >/dev/null 2>&1 || true; done

echo "== same-tree =="
cat "$OUT"
