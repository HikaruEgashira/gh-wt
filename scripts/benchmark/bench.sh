#!/usr/bin/env bash
# gh-wt benchmark harness
# Measures wall-clock time, CPU, RSS, logical & physical disk for:
#   (A) git worktree add        — baseline
#   (B) gh wt add (APFS)        — CoW-backed worktree
# Runs N iterations per condition; between runs the target worktree/cache
# is removed so each measurement starts from a clean state.

set -euo pipefail
ROOT="/private/tmp/ghwt-bench"
REPO="${REPO:-$ROOT/linux}"
GH_WT="${GH_WT:-$(cd "$(dirname "$0")/../.." && pwd)/gh-wt}"
N="${N:-5}"
OUT="${OUT:-$ROOT/results}"
mkdir -p "$OUT"
export GH_WT_CACHE="$ROOT/cache"

# commits to rotate across iterations so each iteration sees a distinct
# tree SHA (defeats any accidental filesystem block cache bias on the cold
# case). We use the first N commits reachable from HEAD.
COMMITS=()
while IFS= read -r c; do COMMITS+=("$c"); done < <(git -C "$REPO" rev-list --max-count="$N" HEAD)

# prep: make N branches, one per commit
prep_branches() {
    for i in $(seq 0 $((N-1))); do
        git -C "$REPO" branch -D "bench-$i" >/dev/null 2>&1 || true
        git -C "$REPO" branch "bench-$i" "${COMMITS[$i]}"
    done
}

# elapsed in seconds (float) via /usr/bin/time -lp on macOS
time_cmd() {
    local out="$1"; shift
    /usr/bin/time -lp "$@" >"$out.stdout" 2>"$out.stderr"
    # parse real/user/sys + peak RSS
    awk '
        /^real /       { real=$2 }
        /^user /       { user=$2 }
        /^sys /        { sys=$2 }
        / maximum resident set size/ { rss=$1 }
        END { printf "%s %s %s %s\n", real, user, sys, rss }
    ' "$out.stderr"
}

logical_size() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
physical_size() { du -skA "$1" 2>/dev/null | awk '{print $1}'; }
file_count()    { find "$1" -type f 2>/dev/null | wc -l | awk '{print $1}'; }

run_baseline() {
    local label=run_baseline
    : > "$OUT/$label.tsv"
    printf 'iter\tbranch\treal\tuser\tsys\trss\tlogical_kb\tphysical_kb\tfiles\n' >> "$OUT/$label.tsv"
    for i in $(seq 0 $((N-1))); do
        local mp="$ROOT/wt-base-$i"
        rm -rf "$mp" 2>/dev/null || true
        git -C "$REPO" worktree prune >/dev/null 2>&1
        # clear FS cache-ish: `sync` only; macOS has no free_pagecache but this still reduces bias
        sync
        local m; m=$(time_cmd "$OUT/$label.$i" git -C "$REPO" worktree add --force "$mp" "bench-$i")
        local real user sys rss; read -r real user sys rss <<<"$m"
        local L P F; L=$(logical_size "$mp"); P=$(physical_size "$mp"); F=$(file_count "$mp")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "bench-$i" "$real" "$user" "$sys" "$rss" "$L" "$P" "$F" >> "$OUT/$label.tsv"
        git -C "$REPO" worktree remove --force "$mp" >/dev/null 2>&1 || rm -rf "$mp"
    done
}

run_ghwt_cold() {
    local label=run_ghwt_cold
    : > "$OUT/$label.tsv"
    printf 'iter\tbranch\treal\tuser\tsys\trss\tlogical_kb\tphysical_kb\tfiles\n' >> "$OUT/$label.tsv"
    for i in $(seq 0 $((N-1))); do
        local mp="$ROOT/wt-ghwt-cold-$i"
        rm -rf "$mp" 2>/dev/null || true
        # wipe per-iteration reference cache so cold path fires every time
        rm -rf "$GH_WT_CACHE"
        git -C "$REPO" worktree prune >/dev/null 2>&1
        sync
        local m; m=$(cd "$REPO" && time_cmd "$OUT/$label.$i" "$GH_WT" add "bench-$i" "$mp")
        local real user sys rss; read -r real user sys rss <<<"$m"
        local L P F; L=$(logical_size "$mp"); P=$(physical_size "$mp"); F=$(file_count "$mp")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "bench-$i" "$real" "$user" "$sys" "$rss" "$L" "$P" "$F" >> "$OUT/$label.tsv"
        git -C "$REPO" worktree remove --force "$mp" >/dev/null 2>&1 || rm -rf "$mp"
    done
}

run_ghwt_warm() {
    # pre-warm: build the single reference by doing one add on bench-0
    local label=run_ghwt_warm
    : > "$OUT/$label.tsv"
    printf 'iter\tbranch\treal\tuser\tsys\trss\tlogical_kb\tphysical_kb\tfiles\n' >> "$OUT/$label.tsv"

    # warm the cache for ALL N branches (so warm add only pays the clonefile step)
    rm -rf "$GH_WT_CACHE"
    for i in $(seq 0 $((N-1))); do
        local mp_warm="$ROOT/wt-warm-seed-$i"
        rm -rf "$mp_warm"
        (cd "$REPO" && "$GH_WT" add "bench-$i" "$mp_warm" >/dev/null)
        git -C "$REPO" worktree remove --force "$mp_warm" >/dev/null 2>&1 || rm -rf "$mp_warm"
    done

    for i in $(seq 0 $((N-1))); do
        local mp="$ROOT/wt-ghwt-warm-$i"
        rm -rf "$mp" 2>/dev/null || true
        git -C "$REPO" worktree prune >/dev/null 2>&1
        sync
        local m; m=$(cd "$REPO" && time_cmd "$OUT/$label.$i" "$GH_WT" add "bench-$i" "$mp")
        local real user sys rss; read -r real user sys rss <<<"$m"
        local L P F; L=$(logical_size "$mp"); P=$(physical_size "$mp"); F=$(file_count "$mp")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "bench-$i" "$real" "$user" "$sys" "$rss" "$L" "$P" "$F" >> "$OUT/$label.tsv"
        git -C "$REPO" worktree remove --force "$mp" >/dev/null 2>&1 || rm -rf "$mp"
    done
}

# Measure incremental disk growth for N concurrent worktrees (same branch).
# baseline: full duplication. gh-wt apfs: clonefile → near-zero extra bytes.
measure_concurrent_footprint() {
    local label=run_footprint
    : > "$OUT/$label.tsv"
    printf 'method\twt_count\tcache_kb\tworktrees_logical_kb\ttotal_physical_kb\n' >> "$OUT/$label.tsv"

    # baseline
    rm -rf "$ROOT"/wt-fp-base-*
    for k in 1 3 5; do
        for j in $(seq 0 $((k-1))); do
            git -C "$REPO" worktree prune >/dev/null 2>&1
            git -C "$REPO" worktree add --force "$ROOT/wt-fp-base-$j" "bench-$j" >/dev/null 2>&1
        done
        local L=0; for d in "$ROOT"/wt-fp-base-*; do [[ -d "$d" ]] && L=$((L + $(logical_size "$d"))); done
        # total physical of all worktrees combined
        local P; P=$(du -sck "$ROOT"/wt-fp-base-* 2>/dev/null | tail -1 | awk '{print $1}')
        printf 'baseline\t%d\t%d\t%d\t%d\n' "$k" 0 "$L" "$P" >> "$OUT/$label.tsv"
        # cleanup all
        for d in "$ROOT"/wt-fp-base-*; do git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"; done
    done

    # gh-wt apfs
    rm -rf "$ROOT"/wt-fp-ghwt-* "$GH_WT_CACHE"
    for k in 1 3 5; do
        rm -rf "$ROOT"/wt-fp-ghwt-*
        git -C "$REPO" worktree prune >/dev/null 2>&1
        for j in $(seq 0 $((k-1))); do
            (cd "$REPO" && "$GH_WT" add "bench-$j" "$ROOT/wt-fp-ghwt-$j" >/dev/null)
        done
        local L=0; for d in "$ROOT"/wt-fp-ghwt-*; do [[ -d "$d" ]] && L=$((L + $(logical_size "$d"))); done
        local C; C=$(du -sk "$GH_WT_CACHE" 2>/dev/null | awk '{print $1}')
        local P; P=$(du -sck "$ROOT"/wt-fp-ghwt-* "$GH_WT_CACHE" 2>/dev/null | tail -1 | awk '{print $1}')
        printf 'gh-wt-apfs\t%d\t%d\t%d\t%d\n' "$k" "$C" "$L" "$P" >> "$OUT/$label.tsv"
    done
    # cleanup final
    for d in "$ROOT"/wt-fp-ghwt-*; do git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"; done
}

echo "[prep] creating $N benchmark branches"
prep_branches

echo "[run] baseline (git worktree add)"
run_baseline

echo "[run] gh-wt cold (no reference cache)"
run_ghwt_cold

echo "[run] gh-wt warm (reference cache populated)"
run_ghwt_warm

echo "[run] concurrent-worktree footprint"
measure_concurrent_footprint

echo "[done] results in $OUT"
