#!/usr/bin/env bash
# gh-wt lifecycle benchmark.
# For each iteration, times the *paired* add and remove for the same
# worktree, so that the reported real-time numbers describe the full
# create-then-destroy cost a developer actually pays.
#
# Conditions (each N iterations on its own branch so there is no tree
# SHA reuse between iterations):
#   baseline    : git worktree add / git worktree remove
#   gh-wt cold  : gh wt add / gh wt remove   (cache wiped per iter)
#   gh-wt warm  : gh wt add / gh wt remove   (reference pre-built)
#
# `gh wt remove <path>` is the non-interactive form added in the same
# change as this script, so removal now measures the real gh-wt code
# path (which on apfs/none boils down to `git worktree remove --force`
# but is reached through the gh-wt dispatcher with its own argv parsing
# and backend resolution).
set -euo pipefail
ROOT="${ROOT:-/private/tmp/ghwt-bench}"
REPO="${REPO:-$ROOT/linux}"
GH_WT="${GH_WT:-$(cd "$(dirname "$0")/../.." && pwd)/gh-wt}"
N="${N:-5}"
OUT="${OUT:-$ROOT/results}"
export GH_WT_CACHE="${GH_WT_CACHE:-$ROOT/cache}"

mkdir -p "$OUT"

[[ -d "$REPO/.git" ]] || { echo "target repo not found: $REPO" >&2; exit 2; }

COMMITS=()
while IFS= read -r c; do COMMITS+=("$c"); done < <(git -C "$REPO" rev-list --max-count="$N" HEAD)
[[ ${#COMMITS[@]} -eq "$N" ]] || { echo "need at least $N commits reachable from HEAD" >&2; exit 2; }

prep_branches() {
    local prefix="$1"
    for i in $(seq 0 $((N-1))); do
        git -C "$REPO" branch -D "$prefix-$i" >/dev/null 2>&1 || true
        git -C "$REPO" branch "$prefix-$i" "${COMMITS[$i]}" >/dev/null
    done
}

cleanup_branches() {
    local prefix="$1"
    for i in $(seq 0 $((N-1))); do
        git -C "$REPO" branch -D "$prefix-$i" >/dev/null 2>&1 || true
    done
}

# /usr/bin/time -lp → "real N\nuser N\nsys N\n..."; print "real user sys".
parse_time() {
    awk '
        /^real /{r=$2} /^user /{u=$2} /^sys /{s=$2}
        END{ printf "%s\t%s\t%s", r, u, s }
    ' "$1"
}

run_condition() {
    local label="$1" prefix="$2" add_cmd="$3" remove_cmd="$4"
    local tsv="$OUT/lifecycle_$label.tsv"
    : > "$tsv"
    printf 'iter\tbranch\tphase\treal\tuser\tsys\n' >> "$tsv"

    prep_branches "$prefix"
    for i in $(seq 0 $((N-1))); do
        local mp="$ROOT/wt-lc-$label-$i"
        local br="$prefix-$i"
        rm -rf "$mp" 2>/dev/null || true
        git -C "$REPO" worktree prune >/dev/null 2>&1 || true

        # condition-specific cache preparation for the add phase
        case "$label" in
            ghwt_cold) rm -rf "$GH_WT_CACHE" ;;
            ghwt_warm) : ;;   # caller already pre-built references
            baseline)  : ;;
        esac

        sync
        local add_err="$OUT/lifecycle_$label.$i.add.err"
        # cmds are bash snippets referencing $BR/$MP/$REPO/$GH_WT.
        # Running through `bash -c` preserves shell operators like `&&`
        # while letting /usr/bin/time measure the full pipeline.
        BR="$br" MP="$mp" REPO="$REPO" GH_WT="$GH_WT" \
            /usr/bin/time -lp bash -c "$add_cmd" >/dev/null 2>"$add_err"
        printf '%d\t%s\tadd\t%s\n' "$i" "$br" "$(parse_time "$add_err")" >> "$tsv"

        sync
        local rm_err="$OUT/lifecycle_$label.$i.rm.err"
        BR="$br" MP="$mp" REPO="$REPO" GH_WT="$GH_WT" \
            /usr/bin/time -lp bash -c "$remove_cmd" >/dev/null 2>"$rm_err" || true
        # defensive: if the remove path left the mountpoint behind
        # (shouldn't happen on success) nuke it so the next iteration
        # starts clean.
        rm -rf "$mp" 2>/dev/null || true
        printf '%d\t%s\tremove\t%s\n' "$i" "$br" "$(parse_time "$rm_err")" >> "$tsv"
    done

    cleanup_branches "$prefix"
}

prewarm_ghwt_cache() {
    local prefix="$1"
    prep_branches "$prefix"
    rm -rf "$GH_WT_CACHE"
    for i in $(seq 0 $((N-1))); do
        local mp="$ROOT/wt-lc-warm-seed-$i"
        rm -rf "$mp"
        (cd "$REPO" && "$GH_WT" add "$prefix-$i" "$mp" >/dev/null)
        git -C "$REPO" worktree remove --force "$mp" >/dev/null 2>&1 || rm -rf "$mp"
    done
}

summarise() {
    local tsv="$1" phase="$2"
    awk -v phase="$phase" '
        BEGIN { FS="\t" }
        NR>1 && $3==phase && $4!="" { n++; v[n]=$4+0; s+=$4; s2+=$4*$4 }
        END {
            if (!n) { printf "n=0\n"; exit }
            m=s/n; var=(n>1)?(s2-n*m*m)/(n-1):0; sd=(var>0)?sqrt(var):0
            for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (v[i]>v[j]) { t=v[i]; v[i]=v[j]; v[j]=t }
            med=(n%2)?v[int(n/2)+1]:(v[n/2]+v[n/2+1])/2
            t975=(n==5)?2.776:2.262
            printf "  n=%d mean=%.3fs sd=%.3f median=%.3f min=%.3f max=%.3f CI95=±%.3f\n",
                n, m, sd, med, v[1], v[n], t975*sd/sqrt(n)
        }
    ' "$tsv"
}

echo "[lifecycle] target repo: $REPO  N=$N"

echo "[run] baseline (git worktree add + git worktree remove)"
run_condition baseline lc-base \
    'git -C "$REPO" worktree add --force "$MP" "$BR"' \
    'git -C "$REPO" worktree remove --force "$MP"'

echo "[run] gh-wt cold (cache wiped per iteration)"
run_condition ghwt_cold lc-cold \
    'cd "$REPO" && "$GH_WT" add "$BR" "$MP"' \
    'cd "$REPO" && "$GH_WT" remove "$MP"'

echo "[prep] warming gh-wt reference cache for warm run"
prewarm_ghwt_cache lc-warm
echo "[run] gh-wt warm (references pre-built)"
run_condition ghwt_warm lc-warm \
    'cd "$REPO" && "$GH_WT" add "$BR" "$MP"' \
    'cd "$REPO" && "$GH_WT" remove "$MP"'

echo
echo "== summary (wall clock, seconds) =="
for label in baseline ghwt_cold ghwt_warm; do
    tsv="$OUT/lifecycle_$label.tsv"
    echo "[$label]"
    echo "  add:"
    summarise "$tsv" add
    echo "  remove:"
    summarise "$tsv" remove
done

echo
echo "[done] TSVs in $OUT/lifecycle_*.tsv"
