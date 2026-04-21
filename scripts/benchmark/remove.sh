#!/usr/bin/env bash
# Measure gh wt remove vs git worktree remove on a large worktree.
# N=5 iterations each. gh-wt non-interactive remove goes through the
# same cleanup code path as interactive; we bypass fzf by scripting.
set -euo pipefail
ROOT="/private/tmp/ghwt-bench"
REPO="$ROOT/linux"
GH_WT="${GH_WT:-$(cd "$(dirname "$0")/../.." && pwd)/gh-wt}"
export GH_WT_CACHE="$ROOT/cache"
OUT="$ROOT/results/remove.tsv"
N="${N:-5}"
mkdir -p "$ROOT/results"
: > "$OUT"
printf 'method\titer\treal\tuser\tsys\n' >> "$OUT"

time_sec() {
    /usr/bin/time -lp "$@" >/dev/null 2>"$1.err" || true
    awk '/^real /{r=$2} /^user /{u=$2} /^sys /{s=$2} END{printf "%s %s %s", r, u, s}' "$1.err"
}

HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
for i in $(seq 0 $((N-1))); do
    git -C "$REPO" branch -D "rm-$i" >/dev/null 2>&1 || true
    git -C "$REPO" branch "rm-$i" "$HEAD_SHA"
done

# baseline: time `git worktree remove`
for i in $(seq 0 $((N-1))); do
    mp="$ROOT/wt-rm-base-$i"
    rm -rf "$mp"; git -C "$REPO" worktree prune >/dev/null 2>&1
    git -C "$REPO" worktree add --force "$mp" "rm-$i" >/dev/null
    sync
    t=$(/usr/bin/time -lp git -C "$REPO" worktree remove --force "$mp" >/dev/null 2>/tmp/rm.err || true
        awk '/^real /{r=$2} /^user /{u=$2} /^sys /{s=$2} END{printf "%s %s %s", r, u, s}' /tmp/rm.err)
    printf 'baseline\t%d\t%s\n' "$i" "$(echo $t | tr ' ' '\t')" >> "$OUT"
done

# gh-wt: seed + time the remove (scripted, bypasses fzf via direct `git worktree remove`)
# gh wt remove uses fzf interactively. For a non-interactive comparison we
# script the exact removal logic gh-wt executes on macOS: git worktree
# remove --force (no umount, no session dir). That's what cmd_remove does
# on apfs/none backends.
rm -rf "$GH_WT_CACHE"
for i in $(seq 0 $((N-1))); do
    mp="$ROOT/wt-rm-ghwt-$i"
    rm -rf "$mp"; git -C "$REPO" worktree prune >/dev/null 2>&1
    (cd "$REPO" && "$GH_WT" add "rm-$i" "$mp" >/dev/null)
    sync
    t=$(/usr/bin/time -lp git -C "$REPO" worktree remove --force "$mp" >/dev/null 2>/tmp/rm.err || true
        awk '/^real /{r=$2} /^user /{u=$2} /^sys /{s=$2} END{printf "%s %s %s", r, u, s}' /tmp/rm.err)
    printf 'gh-wt-apfs\t%d\t%s\n' "$i" "$(echo $t | tr ' ' '\t')" >> "$OUT"
done

for i in $(seq 0 $((N-1))); do git -C "$REPO" branch -D "rm-$i" >/dev/null 2>&1 || true; done

echo "== remove =="
cat "$OUT"
