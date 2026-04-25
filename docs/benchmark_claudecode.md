# Benchmark — Claude Code sandbox (Linux / 9p)

Companion to [`benchmark.md`](./benchmark.md), which measures `git worktree
add` vs. `gh wt add` on macOS / APFS. This document records what happens
when the same harness is pointed at the **Claude Code on the web** sandbox
that this PR was authored in. The headline finding is that `gh wt` is not
runnable here — both backends are blocked — so only the baseline `git
worktree add` numbers are reported, primarily for context.

## 1. System under test

| Component  | Value |
| ---------- | ----- |
| Sandbox    | Claude Code on the web (gVisor / `runsc`) |
| Reported kernel | `Linux 4.4.0 #1 SMP …` (gVisor masquerade; not the host kernel) |
| Userspace  | Ubuntu 24.04.4 LTS |
| CPUs       | 16 logical (`nproc`); model masked, ~2.1 GHz |
| RAM        | ~21 GiB total |
| Root FS    | `9p` (host-passthrough) — `none on / type 9p (… directfs)` |
| Disk free  | ~27 GiB (`/`) |
| `git`      | 2.43.0 |
| `gh-wt`    | HEAD of this branch (`claude/measure-performance-benchmark-fQ3Gk`, 4bd00c4) |

### 1.1 Why gh-wt does not run here

`gh wt add` refuses to start in this sandbox for two independent reasons,
either of which is sufficient on its own:

1. **Kernel-version guard.** `lib/backend.sh::resolve_backend` selects
   `overlayfs` on Linux, and `lib/overlay.sh` requires kernel ≥ 5.11 (for
   unprivileged userns + idmapped overlay support used elsewhere in the
   tool). gVisor reports `4.4.0`, so the guard fails fast:

   ```
   $ gh wt add bench-0 /tmp/wt
   gh-wt: Linux kernel 5.11+ required (found 4.4.0)
   ```

2. **`mount -t overlay` is denied** by the gVisor sandbox even with
   passwordless `sudo`:

   ```
   $ sudo mount -t overlay overlay -o lowerdir=…,upperdir=…,workdir=… /merged
   mount: …: wrong fs type, bad option, bad superblock on overlay, …
   ```

   `/proc/filesystems` lists `overlay`, but `runsc` does not implement
   the mount syscall for it. Bypassing the kernel-version guard would
   therefore not unblock anything.

There is no `apfs` or `none` fallback on Linux (`resolve_backend` is
hard-coded to `overlayfs`), so on this host gh-wt cannot create a
worktree at all. The remainder of this document captures the **baseline**
(`git worktree add`) only.

## 2. Target repository

The same target as `benchmark.md` (so absolute numbers can be compared
side by side):

| Metric        | Value |
| ------------- | ----- |
| Repo          | `llvm/llvm-project` (shallow `--depth 1` then `fetch --depth=10`) |
| HEAD commit   | `6dd373f8a…` (main, fetched 2026-04-25) |
| Tracked files | **174 677** |
| Working-tree size (`du -sk`) | **2.12 GiB** (2 222 209 KiB) |
| Distinct trees in last 5 commits | 5 (one per `bench-{0..4}` branch) |

Five `bench-$i` branches (`i ∈ 0..4`) point at the five most recent
commits; iterations rotate across them so each `add` materialises a
distinct tree SHA.

## 3. Methodology

Identical structure to `benchmark.md` §1.3, with two adaptations:

- `time` is GNU time (`/usr/bin/time -v`) on Linux, not BSD `time -lp`.
  `Elapsed (wall clock)` is parsed as `m:ss[.ss]`; `User time` and
  `System time` are read directly; `Maximum resident set size (kbytes)`
  is the RSS column.
- Only the `baseline` condition runs (gh-wt is unrunnable; see §1.1).
  `cold` / `warm` are not applicable.

```
N=5 bash /tmp/ghwt-bench/bench_baseline.sh
```

Between iterations: `git worktree prune`, `sync`, full `rm -rf` of the
target mountpoint. Iterations are independent but not randomised; run
order is `bench-0 → bench-4` linearly.

## 4. Results

### 4.1 Wall-clock time (`git worktree add --force`)

```
            0s          30s         60s         90s         120s
            |-----------|-----------|-----------|-----------|
  baseline  ████████████████████████████████▍              86.7 ± 23.2 (CV 22 %)
            |-----------|-----------|-----------|-----------|
            0           30          60          90          120
```

| iter | branch  | real (s) | user (s) | sys (s) | RSS (KiB) | logical (KiB) | files  |
| ---: | ------- | -------: | -------: | ------: | --------: | ------------: | -----: |
| 0    | bench-0 |   61.43  |   32.04  |  24.40  |   473 648 |    2 222 209  | 174 659 |
| 1    | bench-1 |   85.88  |   38.03  |  41.53  |   473 336 |    2 222 209  | 174 659 |
| 2    | bench-2 |  106.30  |   41.91  |  56.61  |   474 764 |    2 222 205  | 174 658 |
| 3    | bench-3 |   76.69  |   34.99  |  35.94  |   475 712 |    2 222 205  | 174 658 |
| 4    | bench-4 |  103.19  |   42.45  |  54.01  |   472 004 |    2 222 203  | 174 658 |

| Condition | n | mean (s) | sd | median | min | max | 95 % CI |
| --------- | -: | -------: | -: | -----: | --: | --: | ------: |
| baseline (`git worktree add`) | 5 | **86.70** | 18.68 | 85.88 | 61.43 | 106.30 | ±23.19 |

Per-iteration averages (RSS / CPU / disk):

| metric | mean | unit |
| ------ | ---: | ---- |
| user CPU            |  37.88 | s |
| sys CPU             |  42.50 | s |
| peak RSS            | ~463   | MiB |
| logical worktree size | 2170 | MiB |
| files               | 174 658 | — |

### 4.2 Comparison vs. `benchmark.md` (macOS / APFS, M3)

Same git operation, same target repo, same `N`. The only thing that
changed is the host:

| Host                       | mean `git worktree add` (s) | sd | CV |
| -------------------------- | --------------------------: | -: | -: |
| Apple M3 / APFS (`benchmark.md` §2.1) | **15.17** | 0.36 | 2.4 % |
| Claude Code sandbox / 9p (this doc)   | **86.70** | 18.68 | **22 %** |

The sandbox baseline is **~5.7× slower** in mean and **~52× higher** in
relative variance. The slowdown is dominated by 9p syscall round-trips
and the `runsc` syscall interception overhead — `git`'s checkout phase
fans out to `mkdir` + `open` + `write` + `chmod` per file, and each one
crosses the `runsc` boundary. The variance growth is consistent with
that interpretation: throughput drifted noticeably across the run as the
test directory accumulated entries (iter 0: 61 s; iter 4: 103 s), which
is not a pattern observed on the native APFS host.

### 4.3 Paired add + remove (one shot, not a 5-iteration mean)

A single paired sample, captured separately because the full N=5
lifecycle harness was killed after iter-0 (one paired iteration was
taking >6 minutes — see §6 / Threats):

| phase  | real (s) | user (s) | sys (s) | peak RSS (MiB) |
| ------ | -------: | -------: | ------: | -------------: |
| add    |   79.55  |   37.97  |  35.51  |  461 |
| remove |   53.50  |   20.51  |  30.60  |    9 |
| **round-trip** | **133.05** | — | — | — |

For comparison, the same round-trip on M3 / APFS is ~23.10 s
(`benchmark.md` §2.4). The remove phase is the most striking gap on its
own: ~53 s here vs. ~7.9 s there (~6.7×) — 9p makes `unlink(2)` of 174 k
files particularly costly.

### 4.4 Storage footprint — not measured

`benchmark.md` §2.3 contrasts gh-wt's CoW disk savings against `git
worktree add`'s full-copy footprint. With gh-wt unavailable here, the
only number to report would be the baseline's per-worktree cost, which
is uninteresting in isolation and identical in shape to the macOS
column: roughly the working-tree size per extra worktree
(`du -sk` ≈ 2.12 GiB on llvm-project), with no sharing.

## 5. What this means for `gh-wt` users on Claude Code

- **`gh wt add` cannot create worktrees in this sandbox.** Use plain
  `git worktree add` until either (a) the gVisor host upgrades its
  reported kernel to ≥ 5.11 and admits `overlay` mounts, or (b) gh-wt
  grows a Linux fallback that does not require overlayfs (a `cp -r`
  or `--no-checkout` + manual extraction path; not currently planned —
  see `docs/architecture.md`).
- **Even the baseline is much slower than a native filesystem.** Plan
  for ~1 min per worktree on llvm-class repos, plus another ~50 s to
  remove. Smaller working trees scale roughly linearly with file count.
- **CI / hands-off automation** that calls `gh wt add` from this
  sandbox will exit with `gh-wt: Linux kernel 5.11+ required (found
  4.4.0)` and a non-zero status; treat that as a hard prerequisite check,
  not a transient error.

## 6. Threats to validity

- **n = 5, single host, no randomisation.** Same caveats as
  `benchmark.md` §4.
- **9p performance drift.** During the run, baseline iter time grew
  from 61 s (iter 0) to 103 s (iter 4); the lifecycle phase, started
  after baseline, took >6 minutes for its first add before being
  killed. The drift correlates with cumulative bytes written under
  `/tmp` (10 % → 18 % full), suggesting either 9p metadata cost or
  host-side throttling. Numbers here should be read as
  **order-of-magnitude**, not precise.
- **Lifecycle / footprint phases incomplete.** Only 1 paired
  add+remove sample was captured (§4.3); the harness was stopped before
  the `same-tree` and `distinct-tree` footprint sweeps because, without
  gh-wt to compare against, the data adds nothing not already implied
  by the baseline numbers.
- **gVisor masquerade.** Reported kernel `4.4.0` is `runsc`'s default
  identifier, not the host kernel. The same sandbox would still refuse
  the gh-wt overlayfs path even if the host kernel were 6.x, because
  the mount is the syscall that fails (§1.1, point 2).
- **Comparison to `benchmark.md` is across two hardware classes.** The
  ~5.7× slowdown is the **combined** effect of (CPU, FS, syscall
  interception). It is not an apples-to-apples isolation of any one
  factor; treat it as "what a user actually pays here vs. what a user
  pays on M3/APFS."

## 7. Reproducibility

```bash
# one-time setup (this is what was used to produce §4)
mkdir -p /tmp/ghwt-bench && cd /tmp/ghwt-bench
git clone --depth=1 --single-branch --branch main \
  https://github.com/llvm/llvm-project.git target
git -C target fetch --depth=10 origin main
for i in 0 1 2 3 4; do
  c=$(git -C target rev-list --max-count=5 HEAD | sed -n "$((i+1))p")
  git -C target branch -f "bench-$i" "$c"
done

# the harness used here is a small Linux/GNU-time port of
# scripts/benchmark/bench.sh; it lives at /tmp/ghwt-bench/bench_baseline.sh
# in the run that produced this doc. The relevant inner command is just:
#   /usr/bin/time -v -o run.time \
#     git -C target worktree add --force "$mp" "bench-$i"
N=5 bash /tmp/ghwt-bench/bench_baseline.sh   # baseline only; gh-wt is blocked
```

The TSV produced by the run that backs this document is checked in
under `scripts/benchmark/results/run_baseline_claudecode.tsv`. It is not
auto-regenerated by `scripts/benchmark/bench.sh` (which assumes BSD
`time` and a macOS path layout); the Linux harness is the snippet above.

---

_Measured 2026-04-25 in the Claude Code on the web sandbox against
`llvm/llvm-project` @ 6dd373f8a, with `gh-wt` at HEAD of branch
`claude/measure-performance-benchmark-fQ3Gk` (4bd00c4)._
