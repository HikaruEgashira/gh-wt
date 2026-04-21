#!/usr/bin/env bash
# FPE first-touch latency floor: single clonefile(2) per file.
#
# Whatever a File Provider Extension does on fetchContents, the kernel
# part of its work bottoms out at clonefile(2) of one file from the
# shared reference into the extension's sandbox. This script measures
# that lower bound across file sizes and parallelism, so we have a
# hard number that no FPE implementation can beat.
#
# Result: per-call mean (µs) and ops/sec. Write TSV to
# results/fpe_firsttouch_floor.tsv.
set -euo pipefail
ROOT="${ROOT:-/tmp/ghwt-fpe-floor}"
OUT="${OUT:-$ROOT/results}"
mkdir -p "$ROOT" "$OUT"

# clonefile(2) is directly exposed via `cp -c`. Each `cp -c` invocation
# forks+execs — expensive at 1k+ iterations — so we batch via a Python
# ctypes helper that calls clonefile() in-process.
HELPER="$ROOT/clone_bench.py"
cat >"$HELPER" <<'PY'
"""Tiny clonefile(2) driver. Reads src/dst pairs from argv1 (tsv),
calls clonefile for each, prints total seconds + count."""
import ctypes, ctypes.util, os, sys, time
libc = ctypes.CDLL(ctypes.util.find_library("c"))
clonefile = libc.clonefile
clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
clonefile.restype = ctypes.c_int

pairs_file, = sys.argv[1:]
pairs = []
with open(pairs_file, "r") as f:
    for line in f:
        src, dst = line.rstrip("\n").split("\t")
        pairs.append((src.encode(), dst.encode()))

t0 = time.perf_counter_ns()
fail = 0
for src, dst in pairs:
    rc = clonefile(src, dst, 0)
    if rc != 0:
        fail += 1
t1 = time.perf_counter_ns()
print(f"{len(pairs)}\t{t1 - t0}\t{fail}")
PY

make_sources() {
    local count="$1" size_kb="$2" dir="$3"
    rm -rf "$dir"
    mkdir -p "$dir"
    # generate N files of SIZE kb. /dev/random is slow; dd from zero.
    local i
    for i in $(seq 0 $((count - 1))); do
        dd if=/dev/zero of="$dir/f$i" bs=1024 count="$size_kb" 2>/dev/null
    done
}

bench() {
    local count="$1" size_kb="$2" parallel="$3"
    # cache key includes count: srcdir generated for 100 files must not be
    # silently reused for a 1000-file run (the missing f100..f999 would
    # produce an empty pair list and mask the problem as a zero-division).
    local srcdir="$ROOT/src-${size_kb}-${count}"
    local dstroot="$ROOT/dst-$size_kb-$parallel"
    [[ -d "$srcdir" ]] || make_sources "$count" "$size_kb" "$srcdir"
    rm -rf "$dstroot"
    mkdir -p "$dstroot"
    sync

    # write pairs files, one per worker
    local i pair
    for w in $(seq 0 $((parallel - 1))); do
        : > "$ROOT/pairs.$w"
    done
    i=0
    for src in "$srcdir"/f*; do
        local w=$((i % parallel))
        printf '%s\t%s\n' "$src" "$dstroot/$(basename "$src").$w" >> "$ROOT/pairs.$w"
        i=$((i + 1))
    done

    local t0 t1 ns_total=0 n_total=0 fail_total=0
    t0=$(perl -MTime::HiRes=time -e 'print int(time()*1e9)')
    pids=()
    for w in $(seq 0 $((parallel - 1))); do
        python3 "$HELPER" "$ROOT/pairs.$w" > "$ROOT/out.$w" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    t1=$(perl -MTime::HiRes=time -e 'print int(time()*1e9)')

    for w in $(seq 0 $((parallel - 1))); do
        local line; line=$(cat "$ROOT/out.$w")
        local n ns fail; IFS=$'\t' read -r n ns fail <<<"$line"
        n_total=$((n_total + n))
        ns_total=$((ns_total + ns))
        fail_total=$((fail_total + fail))
    done

    local wall_ns=$((t1 - t0))
    local n_success=$((n_total - fail_total))
    if (( fail_total > 0 )); then
        printf '[fpe-floor] WARN size=%skb P=%s: %d/%d clonefile calls failed\n' \
            "$size_kb" "$parallel" "$fail_total" "$n_total" >&2
    fi
    # per-call latency in µs (sum of kernel time / successful calls —
    # failures are excluded so a partial-failure run can't pull the mean
    # toward zero).
    local per_call_us=0
    if (( n_success > 0 )); then
        per_call_us=$((ns_total / n_success / 1000))
    fi
    # wall-clock throughput (files per second)
    local ops_per_sec=0
    if (( wall_ns > 0 )); then
        ops_per_sec=$((n_success * 1000000000 / wall_ns))
    fi
    printf '%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n' \
        "$count" "$size_kb" "$parallel" "$ns_total" "$wall_ns" \
        "$per_call_us" "$ops_per_sec" "$fail_total"
}

echo "[fpe-floor] results -> $OUT/fpe_firsttouch_floor.tsv"
printf 'count\tsize_kb\tparallel\tsum_ns\twall_ns\tper_call_us\tops_per_sec\tfail\n' \
    > "$OUT/fpe_firsttouch_floor.tsv"

# Three axes: N files × file size × parallelism.
# N=1000 is enough for stable latency without taking forever.
# Sizes span the git reality: header (1-4 kb), source (8-64 kb), big (256+ kb).
# Parallelism: 1 (serial first-touch), 4 (our parallel clonefile baseline), 8.
for size_kb in 1 16 64 256; do
    for parallel in 1 4 8; do
        row=$(bench 1000 "$size_kb" "$parallel")
        echo "  size=${size_kb}kb P=${parallel}: $row"
        echo "$row" >> "$OUT/fpe_firsttouch_floor.tsv"
    done
done

echo
echo "== per-call floor (µs) =="
awk 'BEGIN{FS="\t"} NR>1 {printf "size=%skb P=%s: per-call=%sµs throughput=%s ops/s\n", $2, $3, $6, $7}' \
    "$OUT/fpe_firsttouch_floor.tsv"
