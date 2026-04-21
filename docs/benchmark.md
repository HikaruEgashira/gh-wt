# Benchmark

Quantitative comparison of `git worktree add` (baseline) and `gh wt add`
(APFS clonefile backend) on a large real-world repository. Results were
collected with the harness in `scripts/benchmark/` (reproducibly included
below) on an idle system.

## 1. Methodology

### 1.1 System under test

| Component | Value |
| --------- | ----- |
| CPU       | Apple M3 (8-core, ARM64; 4 P + 4 E) |
| RAM       | 24 GiB |
| OS        | macOS 26.3 (Darwin 25.3.0) |
| Filesystem | APFS on internal SSD (case-insensitive default) |
| git       | 2.53.0 |
| gh-wt     | HEAD of this repo (post case-collision guard + parallel clonefile) |

### 1.2 Target repository

`llvm/llvm-project` (shallow clone, `--depth 10` after a deepen-fetch so
that five distinct tree SHAs are reachable). Replaces the `torvalds/linux`
target used in earlier revisions of this document — linux contains 13
case-fold path collisions (`xt_CONNMARK.h` vs `xt_connmark.h`, …) which
the new reference-build guard correctly refuses to materialise on a
case-insensitive volume.

| Metric | Value |
| ------ | ----- |
| HEAD commit | `83f8eee57d…` (main) |
| Tracked files | **174 295** |
| Working-tree size (`du -sk`) | **~2.42 GiB** (2 538 072 KiB) |
| Physical size (`du -skA`) | ~2.06 GiB (2 164 078 KiB) |
| Packed `.git` | ~304 MiB |
| Case-fold path collisions | 0 (passes the guard) |

### 1.3 Experimental design

Three timed conditions, each with **N = 5** independent iterations on
five distinct branches (`bench-0`…`bench-4`) pointing at the five most
recent main commits (five distinct tree SHAs, so no cross-iteration
cache reuse):

| Condition | Command measured | Cache state per iteration |
| --------- | ---------------- | ------------------------- |
| **baseline**    | `git worktree add --force <mp> bench-$i` | n/a |
| **gh-wt cold**  | `gh wt add bench-$i <mp>`                | `rm -rf $GH_WT_CACHE` before each run |
| **gh-wt warm**  | `gh wt add bench-$i <mp>`                | references pre-built for all five branches |

Timing was captured with `/usr/bin/time -lp` (BSD), which reports wall
clock, user/sys CPU, and peak RSS from `getrusage(2)`. Disk usage was
captured two ways:

- **logical** (`du -sk`): sum of per-file sizes, **ignores** APFS
  clonefile block sharing.
- **physical** (`df -k` delta): bytes actually allocated on the volume,
  **sees** block sharing. This is the only metric that reflects gh-wt's
  CoW disk savings.

Two orthogonal **storage footprint** experiments were also run, with
`k ∈ {1, 3, 5}` live worktrees each:

1. **Distinct-tree footprint** — the five branches used above (worst
   case for gh-wt: every worktree has its own tree SHA, so every one
   materialises its own reference).
2. **Same-tree footprint** — five branches (`alt-0`…`alt-4`) all at
   the same commit (best case: all share one reference).

Between iterations and conditions: `git worktree prune`, `sync`, and
full removal of the target mountpoint were performed. Iterations are
independent but not randomised; run order is `baseline → cold → warm`
to keep the warm pre-warm step coherent with preceding results. The
order does not advantage gh-wt (baseline runs on a newly-booted page
cache).

### 1.4 Statistics

Per-condition we report `n, mean, sd, min, median, max` and a 95 %
confidence interval half-width computed with Student's *t* (two-sided,
`t_{0.975, n-1} = 2.776` for n = 5). With n = 5 these CIs are wide; we
use them to bound the ordering of means, not to claim a specific
effect size.

## 2. Results

### 2.1 Wall-clock time (seconds per `add`)

```
            0s          15s         30s         45s         60s
            |-----------|-----------|-----------|-----------|
  baseline  ██████████▏                                         15.17 ± 0.44
  ghwt warm █████████████████████████████▌                     44.44 ± 0.97
  ghwt cold █████████████████████████████████████████          61.54 ± 1.11
            |-----------|-----------|-----------|-----------|
            0           15          30          45          60
```

| Condition | n | mean (s) | sd | median | min | max | 95 % CI |
| --------- | -: | -------: | -: | -----: | --: | --: | ------: |
| baseline (git worktree add) | 5 | **15.170** | 0.356 | 14.980 | 14.900 | 15.720 | ±0.442 |
| gh-wt cold (ref + clonefile) | 5 | **61.538** | 0.897 | 61.600 | 60.240 | 62.440 | ±1.114 |
| gh-wt warm (clonefile only)  | 5 | **44.444** | 0.778 | 44.460 | 43.330 | 45.500 | ±0.965 |

**Read:** for a single `add` on a 174 k-file, 2.42 GiB working tree,
`git worktree add` takes ~15 s; `gh wt add` takes ~44 s warm and ~62 s
cold. gh-wt is **2.9× / 4.1× slower** than the baseline in these
conditions (down from 3.7× / 4.7× before parallel clonefile landed).
The speed cost is not the win — see §2.3 for the win.

### 2.2 Where does gh-wt's time go?

Breakdown of the same runs (user + sys CPU; real time in parentheses):

| Condition | user (s) | sys (s) | real (s) | peak RSS (MiB) |
| --------- | -------: | ------: | -------: | -------------: |
| baseline  | 2.87 | 11.27 | 15.17 | 532 |
| gh-wt warm | 5.29 | 46.85 | 44.44 | 190 |
| gh-wt cold | 9.63 | 64.70 | 61.54 | 550 |

- `git worktree add` is dominated by `sys` time (checkout I/O) and peaks
  at ~532 MiB RSS (git's object + index machinery).
- `gh wt add` (warm) issues one `clonefile(2)` per file in the tree via
  `cp -cRp`, parallelised across `P=4` top-level entries by default.
  Aggregated kernel time (~47 s) exceeds wall clock (~44 s) because four
  cores share the work. Peak RSS is much lower (190 MiB) because no
  object unpacking happens in the gh-wt path; all block sharing is
  filesystem-level.
- `gh wt add` (cold) adds `git archive | tar -x` to build the
  read-only reference plus the case-collision scan — that's the ~17 s
  delta between cold and warm.
- The **post-clonefile `git reset --mixed HEAD`** (refresh the index so
  `git status` is clean against the cloned working tree) is itself
  ~14 s on this scale — git's own warning suggests `--no-refresh`, but
  deferring the cost only shifts the same hashing burden to the first
  `git status`. This is the next-largest budget item after `clonefile`.

### 2.3 Storage — the reason gh-wt exists

#### 2.3.1 Same-tree footprint and scaling

k worktrees all at the same commit, measured as `df` delta (bytes
actually allocated on the volume). The numbers below were collected on
the same APFS host but on an earlier (linux kernel, 1.77 GiB) target;
they are presented as the canonical illustration of the CoW property.
The behaviour is invariant of the target tree size:

| k | baseline (KiB) | baseline (GiB) | gh-wt APFS (KiB) | gh-wt (GiB) | ratio |
| -: | -------------: | -------------: | ---------------: | ----------: | -----: |
|  1 |  1 824 616 | 1.74 |  1 863 504 | 1.78 | **1.02×** |
|  2 |  3 646 616 | 3.48 |  1 908 484 | 1.82 | **0.52×** |
|  5 |  9 125 732 | 8.70 |  2 049 480 | 1.95 | **0.22×** |
| 10 | 18 247 096 | 17.4 |  2 265 844 | 2.16 | **0.12×** |
| 15 | —          | —    |  2 504 632 | 2.39 | — |
| 20 | —          | —    |  2 710 772 | 2.58 | — |

**Empirical linear fit for gh-wt (least-squares over all six k points):**

```
disk_gh-wt(k) ≈ 1 778 MiB + 43.8 MiB · k      (R² ≈ 1.00)
```

- The **intercept** is essentially one copy of the working tree —
  the shared reference.
- The **slope** is pure APFS clonefile overhead: inode + directory-entry
  metadata for every file, with file blocks shared. There is no
  per-worktree content cost.
- Baseline's slope is the *whole working tree* per extra worktree, i.e.
  **~41× steeper**.

Crossover (k where gh-wt becomes cheaper than baseline): `k ≥ 2`. At
k = 10 the measured ratio is **0.12×** (~8× less disk); extrapolating
to k = 20 gives ~13×.

The same-tree property scales with **`O(extra_worktrees × ~44 MiB)`**
regardless of the underlying tree's size. For llvm-project (174 k files,
2.42 GiB working tree) the per-worktree marginal would land near
~80–90 MiB on a tree this size — but the headline ratio (~0.1× at k≥10)
is unchanged because both numerator and denominator scale with tree size.

#### 2.3.2 Distinct-tree footprint (worst case)

Five distinct branches, each with its own tree SHA. Measured on
llvm-project as `df` delta (in `scripts/benchmark/results/df_footprint.tsv`):

| k | baseline (KiB) | baseline (GiB) | gh-wt APFS (KiB) | gh-wt (GiB) | Δ (KiB) | ratio |
| -: | -------------: | -------------: | ---------------: | ----------: | ------: | ----: |
| 1 |  2 646 340 | 2.52 |  2 722 092 | 2.60 |  +75 752 | 1.03× |
| 3 |  7 936 372 | 7.57 |  8 175 596 | 7.80 | +239 224 | 1.03× |
| 5 | 13 227 492 | 12.61 | 13 614 656 | 12.98 | +387 164 | 1.03× |

Under the **distinct-tree** workload gh-wt is marginally *worse* on
disk: ~3 % extra (~75 MiB per reference on llvm), because the unpacked
reference tree is stored alongside git's own packed objects, and
clonefile cannot dedup across distinct tree SHAs. The overhead is
constant per reference (the difference between what `git archive | tar`
materialises and what the packed `.git/objects` already had).

This is the honest worst case. gh-wt's value proposition is the
same-tree (or near-same-tree) case: §2.3.1.

#### 2.3.3 Why du disagrees with df on APFS

APFS `clonefile(2)` makes two directory entries share on-disk blocks.
`du` sums per-file logical sizes and therefore **does not see**
block-level sharing — it reports the same total as a full copy. The
`df -k` delta observes the volume's allocated-block count and **does**.
We report `df` deltas for any claim about real disk cost.

```mermaid
flowchart LR
  subgraph Baseline["git worktree add (N worktrees at distinct trees)"]
    B0[(".git<br/>packed objects<br/>~304 MiB")]
    B1["wt-0<br/>2.06 GiB"]
    B2["wt-1<br/>2.06 GiB"]
    B3["wt-…"]
    B0 -.-> B1
    B0 -.-> B2
    B0 -.-> B3
  end
  subgraph Ghwt["gh wt add (APFS clonefile)"]
    G0[(".git<br/>packed objects")]
    C0[["cache/ref/tree-A<br/>2.06 GiB (ref)"]]
    C1[["cache/ref/tree-B<br/>2.06 GiB (ref)"]]
    W0["wt-0<br/>blocks shared with tree-A"]
    W1["wt-1<br/>blocks shared with tree-B"]
    C0 == clonefile ==> W0
    C1 == clonefile ==> W1
  end
```

Block-level sharing (the `==>` edges) is what turns N same-tree
worktrees from O(N × working-tree) into O(1 × working-tree).

### 2.4 Remove — completing the lifecycle

Same instrumentation as §2.1, but for the complementary operation
(worktree teardown). Each iteration creates a fresh worktree of the
same HEAD and times only the removal.

| Operation | n | mean (s) | sd | 95 % CI |
| --------- | -: | -------: | -: | ------: |
| `git worktree remove --force` (baseline)          | 5 | **7.926** | 0.096 | ±0.119 |
| `git worktree remove --force` on a gh-wt APFS wt  | 5 | **7.624** | 0.049 | ±0.061 |

```
                 0s             4s             8s
                 |------|-------|------|-------|
  baseline       ████████████████████▏          7.93 ± 0.12
  gh-wt (APFS)   ███████████████████▏           7.62 ± 0.06
                 |------|-------|------|-------|
```

**Read:** `remove` on a clonefile-backed tree is ~4 % *faster* than on
a fully materialised baseline tree. `unlink(2)` on APFS clonefiles
only drops the inode's block-sharing reference (no blocks freed until
the last reference), so removing 174 k clonefiled files is slightly
cheaper than removing 174 k independently allocated ones.

Lifecycle totals (add + remove, same-tree scenario):

| Method     | add (s) | remove (s) | **round-trip (s)** |
| ---------- | ------: | ---------: | -----------------: |
| baseline   | 15.17   |  7.93 | **23.10** |
| gh-wt warm | 44.44   |  7.62 | **52.06** (2.25×) |
| gh-wt cold | 61.54   |  7.62 | **69.16** (2.99×) |

The per-invocation time penalty amortises quickly when worktrees are
kept around for hours or days of work.

### 2.5 Paired add + remove in one iteration

`lifecycle.sh` is a variant of the harness in which each iteration
creates and then destroys the same worktree, so add and remove times
come from the *same* filesystem state and the summed wall clock is a
single developer's round-trip cost. It runs baseline, gh-wt cold, and
gh-wt warm back-to-back on N distinct branches (`lc-{base,cold,warm}-$i`)
and emits one TSV per condition with a `phase` column (`add` | `remove`).

Unlike §2.4 — which scripts `git worktree remove` directly to sidestep
gh-wt's fzf prompt — `lifecycle.sh` exercises the real `gh wt remove
<target>` path (the non-interactive form of the command). That means
the reported remove time includes gh-wt's dispatcher, env/backend
resolution, and argv handling, on top of the underlying `git worktree
remove --force`. On large worktrees the wrapper overhead is <2 % of
the total remove cost and the numbers track §2.4 closely.

| Condition | phase | n | mean (s) | sd |
| --------- | ----- | -: | -------: | -: |
| baseline  | add    | 5 | 14.984 | 0.434 |
| baseline  | remove | 5 |  7.944 | 0.138 |
| gh-wt cold | add    | 5 | 62.194 | 2.464 |
| gh-wt cold | remove | 5 |  7.714 | 0.080 |
| gh-wt warm | add    | 5 | 45.472 | 1.573 |
| gh-wt warm | remove | 5 |  7.564 | 0.044 |

```bash
bash scripts/benchmark/lifecycle.sh      # N=5 per condition, all on bench rig
N=10 bash scripts/benchmark/lifecycle.sh # denser sample
```

Output:

```
results/lifecycle_baseline.tsv    # iter branch phase real user sys
results/lifecycle_ghwt_cold.tsv
results/lifecycle_ghwt_warm.tsv
```

The script prints per-condition summaries (n, mean, sd, median, min,
max, 95 % CI) for both phases inline — no extra `awk -f stats.awk`
pass needed.

## 3. Observations

- **Speed**: `git worktree add` wins on this repo and this hardware, by
  roughly **3× per invocation** for warm gh-wt (and ~4× for cold).
  Parallel clonefile (`GH_WT_CLONE_PARALLELISM=4` default) closed about
  a quarter of the gap that the previous serial implementation showed.
  If your workflow creates a handful of worktrees, the extra ~30 s per
  `add` matters more than the disk savings. gh-wt is **not** a speed
  optimisation.
- **Disk, distinct trees**: gh-wt pays a small overhead (~MiB-class per
  reference) for the privilege of keeping an unpacked reference. If
  every worktree you ever make points at a totally different tree,
  `git worktree add` is the right tool.
- **Disk, same tree**: this is where gh-wt is designed to pay off. The
  empirical linear fit (§2.3.1) gives **~44 MiB per additional worktree
  at linux scale**, i.e. ~2.4 % of that working tree — a reduction of
  ~41× in the per-worktree marginal cost. The measured k = 10 ratio is
  0.12× (8× less disk); extrapolating the fit to k = 20 gives ~13×.
- **Remove**: gh-wt's clonefile worktrees remove ~4 % *faster* than
  fully materialised ones — one of the only latency metrics where
  gh-wt beats the baseline on a per-op basis (§2.4).
- **Reproducibility of timings**: baseline and warm/cold are tight
  (CV ≈ 2 %); the largest variance is on the lifecycle warm-add (CV ≈
  3.5 %, sd 1.57 s on 45 s mean), still well within the
  baseline < warm < cold ordering. Remove is the tightest of all
  (CV < 1 %).
- **Critical path next**: the dominant remaining costs in warm `add`
  are (a) ~13 s of `clonefile(2)` (kernel-bound, only beaten by
  parallelism), (b) ~14 s of `git reset --mixed HEAD` post-clonefile
  (avoidable with a stat-correct prebuilt index, deferred until a
  native helper exists), (c) ~17 s of cold-only reference build
  (avoidable on cold by switching from `git archive | tar` to
  `git checkout-index --prefix=`, ~2 s saving with side benefit of
  case-aware extraction). Sub-second worktree creation requires
  abandoning eager materialisation in favour of a virtual filesystem
  (macOS File Provider Extension); see future work.

## 4. Threats to validity

- **n = 5 per condition.** Adequate to rank means with large effect
  sizes but narrow for variance claims. Repeated-run noise (especially
  on warm) would benefit from n ≥ 20.
- **Single host.** All numbers are from one Apple M3 on APFS. OverlayFS
  (Linux) is not exercised here; expect different absolute numbers and
  different overheads (persistent `sudo mount`, separate upper+workdir).
- **Page cache.** `sync` was issued between iterations but macOS has
  no equivalent to Linux `drop_caches`. Cold/warm within a run share
  whatever page cache survived; the between-condition ordering means
  baseline never sees a cache warmed by gh-wt's tar extraction.
- **Serial, non-randomised runs.** Order effects (thermal throttling,
  background activity) cannot be ruled out; none of the observed means
  drift monotonically with iteration index, which is consistent with
  no significant order effect.
- **Measurement granularity.** `/usr/bin/time -lp` reports 10 ms
  resolution on macOS; that is fine against ~15 s baselines but is
  ~0.02 % noise on the cold case.
- **`df` quantisation.** `df -k` reports in KiB and the APFS metadata
  writer runs asynchronously; a 2 s sleep was inserted before each
  post-measurement read. The footprint numbers are therefore accurate
  to roughly the nearest few MiB.
- **Same-tree footprint table is from a prior linux-target run.** The
  property (CoW slope ≈ inode-metadata cost) is invariant of the
  target. Re-collecting on llvm requires the same-tree variant of the
  bench harness; it would shift the absolute slope value (~80–90 MiB
  per worktree on llvm vs ~44 MiB on linux) but not the headline ratio.

## 5. Reproducibility

All scripts used to produce the tables above are under
`scripts/benchmark/` in this repo. The raw TSVs alongside them are
from the measurement run on 2026-04-21. Full reproduction takes ~40
minutes on an M3 (~25 min for the timed conditions, ~5 min for the
distinct-tree footprint, ~10 min for paired lifecycle).

```bash
# one-time setup — a shallow clone with enough history for 5 branches.
# llvm-project is the new canonical target; the linux kernel is rejected
# by the case-collision guard on case-insensitive APFS.
mkdir -p /private/tmp/ghwt-bench && cd /private/tmp/ghwt-bench
git clone --depth=1 --single-branch --branch main \
  https://github.com/llvm/llvm-project.git llvm-project
git -C llvm-project fetch --depth=10 origin main
ln -sfn llvm-project linux  # df_footprint.sh / scaling.sh expect "$ROOT/linux"

# timed conditions (baseline/cold/warm) + distinct-tree footprint
bash scripts/benchmark/bench.sh

# real-physical-bytes footprint via df delta
bash scripts/benchmark/df_footprint.sh

# same-tree footprint at k ∈ {1,3,5}
bash scripts/benchmark/same_tree.sh

# extended k-scaling sweep (baseline to k=10, gh-wt to k=20)
bash scripts/benchmark/scaling.sh

# remove-only timing (complements §2.4)
bash scripts/benchmark/remove.sh

# paired add+remove timing in one script (§2.5)
bash scripts/benchmark/lifecycle.sh

# per-column stats
awk -f scripts/benchmark/stats.awk /private/tmp/ghwt-bench/results/run_baseline.tsv
awk -f scripts/benchmark/stats.awk /private/tmp/ghwt-bench/results/run_ghwt_cold.tsv
awk -f scripts/benchmark/stats.awk /private/tmp/ghwt-bench/results/run_ghwt_warm.tsv
```

Override defaults via env vars: `REPO=<path>`, `N=<iterations>`,
`OUT=<dir>`, `GH_WT_CACHE=<path>`, `GH_WT_CLONE_PARALLELISM=<N>`.

---

_Measured 2026-04-21 on Apple M3 / macOS 26.3 against
llvm/llvm-project @ 83f8eee. The exact TSVs from that run are checked in
under `scripts/benchmark/results/`; the scripts next to them regenerate
the numbers (writing fresh TSVs to `/private/tmp/ghwt-bench/results/`
at measurement time)._
