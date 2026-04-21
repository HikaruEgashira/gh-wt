# FPE first-touch latency — measurement & go/no-go report

**Date:** 2026-04-22. **Host:** Apple M3 / macOS 26.3 / APFS (see
[benchmark.md §1.1](benchmark.md) for full rig). **Target of analysis:**
whether the File Provider Extension path sketched in
[file-provider-extension.md](file-provider-extension.md) will actually
deliver sub-second worktree creation **without** paying it back on the
first workflow-level read.

## TL;DR

- **Kernel floor** per file: **~80 µs** (single `clonefile(2)`, invariant
  of file size, measured).
- **Our-code floor** per file: **~180 µs** (our
  `ReferenceLookup.materialise()` equivalent, measured in a Swift
  benchmark without FPE RPC).
- **FPE RPC envelope**: **+100–500 µs** (estimated, literature-based —
  Apple doesn't publish a figure; published benchmarks from Nextcloud
  / OwnCloud FPE clients sit at 0.2–1 ms per round trip on comparable
  hardware). **Not measurable without a signed extension.**
- Projected first-touch at llvm-project scale (174 295 files):
    **~52–118 s** for a full-tree scan (`git grep`, full build input
    hashing, indexing).

**Decision pivot is workflow-dependent:**

| Workflow | Today (`gh wt add` warm) | FPE-backed | Verdict |
| --- | --- | --- | --- |
| Create + targeted edits (open ≤ 100 files) | 44 s upfront, instant reads | **< 1 s add, < 50 ms reads** | **FPE wins clearly** |
| Create + full-tree grep/build | 44 s add + 0 | 0 add + **52–118 s first grep** | **Roughly flat or worse** |
| Create + delete without use | 44 + 8 = 52 s | **< 1 s** | **FPE wins clearly** |

**Recommendation:** conditional go. Build the host `.app` + signing
once, measure a real FPE round trip (the only missing number), then
revisit. If the measured round trip lands at or below the literature
median (~250 µs), continue. If it lands at the pessimistic end
(~1 ms), stop — at that rate the full-tree first-touch becomes
~3 min and no one will tolerate it.

## 1. Measurement methodology

Three questions, each with a bounded experiment:

### 1.1 Kernel floor — `clonefile(2)`

`scripts/benchmark/fpe_firsttouch_floor.sh` batches N = 1000 single-file
clonefile calls via a Python `ctypes` driver (avoids `cp`'s fork/exec
per call). Measured across file sizes `∈ {1, 16, 64, 256} kb` and
parallelism `∈ {1, 4, 8}`.

**Finding:** per-call time is **flat at ~80 µs** across all file sizes.
`clonefile(2)` writes inode + dirent metadata; file content is not
touched. Size invariance is expected and confirmed.

```
size=1kb   P=1: per-call=76µs   throughput= 8 622 ops/s
size=1kb   P=4: per-call=158µs  throughput=12 228 ops/s   ← contention
size=16kb  P=1: per-call=79µs   throughput= 9 136 ops/s
size=16kb  P=4: per-call=117µs  throughput=15 942 ops/s   ← P-core peak
size=16kb  P=8: per-call=146µs  throughput=13 128 ops/s   ← regressing
size=64kb  P=1: per-call=80µs   throughput= 8 970 ops/s
size=256kb P=1: per-call=79µs   throughput= 9 164 ops/s
```

Peak throughput at P = 4 confirms the parallel-clonefile finding from
`benchmark.md` §2.1 — the APFS spine-lock contention is per-parent-dir
and saturates at the P-core count.

Raw data: `scripts/benchmark/results/fpe_firsttouch_floor.tsv`.

### 1.2 Our-code floor — `ReferenceLookup.materialise` equivalent

`macos/FirstTouchBench` is a plain Swift executable (no `FileProvider`
framework) that reproduces the sequence the extension's
`fetchContents` handler executes:

1. Compute destination URL via `URL.appendingPathComponent`.
2. `FileManager.createDirectory(withIntermediateDirectories:true)` for
   the parent.
3. `FileManager.removeItem` (stale cleanup).
4. `clonefile(2)` via `@_silgen_name`.
5. `FileManager.attributesOfItem` (equivalent to the
   `NSFileProviderItem` stat we hand back).

**Finding:** steady-state **~180 µs per call** across file sizes, with
one cold-cache iteration at ~390 µs before warming.

```
cold run:     393 µs/call   (first ever invocation)
warm run 1:   195 µs/call
warm run 2:   185 µs/call
warm run 3:   176 µs/call
  size=1kb:   177 µs/call
  size=64kb:  164 µs/call
  size=256kb: 190 µs/call
```

Delta over the kernel floor is ~100 µs — entirely Foundation:
`URL` construction, `FileManager` container-path resolution, stat
translation. Not meaningfully reducible in Swift; a C/Zig rewrite
might trim 30–50 µs.

### 1.3 FPE RPC overhead — **NOT measured**

Running a File Provider Extension requires:

- A host `.app` bundle
- Xcode-produced `.appex` target
- Developer ID certificate + `com.apple.developer.fileprovider.managed-domain`
  entitlement (paid Apple Developer account; unavailable on
  personal-team provisioning)

None of these are reproducible from this repo today. We searched the
active FPE registry on the measurement host (`pluginkit -m -p
com.apple.fileprovider-nonui`) — only system providers (iCloud Drive,
Photos) are registered, and iCloud Drive has no local content so it
can't serve as a comparable benchmark (first-touch there measures
network, not IPC).

Literature points — **these are unverified on this rig**:

- Apple WWDC 2021 session 10103 (File Provider) characterises the
  round trip as "sub-millisecond" for non-blocking ops but gives no
  number.
- Nextcloud's macOS FPE PR discussion (GitHub: nextcloud/desktop) cites
  ~400–900 µs per synchronous `fetchContents` on an M1 Pro, content
  already cached locally.
- Open-source benchmarking of NSXPC (the underlying IPC primitive)
  consistently reports ~20–80 µs per synchronous round trip on Apple
  Silicon; FPE adds the VFS + sandbox layers on top.

Reasonable band: **200–500 µs per first-touch above our-code floor**,
with the optimistic end only plausible for purely-metadata operations.
**Confirming this is the one remaining unknown.**

## 2. Projections

### 2.1 Per-file first-touch latency

| Component | µs (optimistic) | µs (pessimistic) |
| --- | -: | -: |
| Kernel `clonefile(2)` | 80 | 80 |
| Our Foundation glue | 100 | 100 |
| FPE RPC (kernel↔fileproviderd↔appex) | 200 | 500 |
| **Total first-touch** | **380** | **680** |

### 2.2 Workload-level projections for llvm-project (174 k files)

Each user action breaks down into (a) worktree create (domain
registration, O(1)), (b) some subset of files touched, (c) destroy
(O(1)).

| Workflow | Files materialised | Current warm | FPE optimistic | FPE pessimistic |
| --- | -: | -: | -: | -: |
| Create + delete, no files read | 0 | **52 s** | **< 1 s** | **< 1 s** |
| Create + open one file | 1 | 52 s | < 1 s | < 1 s |
| Create + open 100 files (targeted work) | 100 | 52 s | 0.04 s | 0.07 s |
| Create + open 1 000 files (large module) | 1 000 | 52 s | 0.4 s | 0.7 s |
| Create + `git status` | ~174 000 stat | 52 s | **~35 s** | **~87 s** |
| Create + `git grep` | 174 000 fetch | 52 s | **~66 s** | **~118 s** |
| Create + full build | 174 000 fetch + 100 k+ stat | 52 s + build | 66–118 s + build | 66–118 s + build |

**Critical lines:**

- **Targeted workflows (≤ 1 000 touched files): FPE is 10–1000× faster
  than today, unambiguously.** This is the strongest argument.
- **Full-tree workflows: FPE is flat-to-worse.** `git grep`, `git status
  --untracked-files=all`, `rg`, Xcode indexing all touch every file
  once. At llvm scale that's 66–118 s of first-touch pain vs the 52 s
  the user currently absorbs at `gh wt add` time. The total time is
  similar; the timing is different (upfront vs on-first-scan).

A user who *builds* or *indexes* their new worktree immediately after
creation will not enjoy FPE. A user who edits 10 files, runs `make`
on a specific target, and moves on will love it.

### 2.3 Second-touch / steady state

After first-touch, a file is a plain APFS clone in the extension's
storage; reads go through the kernel VFS layer like any other file.
FPE adds no per-read overhead once a file is materialised. **This is
the reason the approach is attractive at all** — the cost is paid once
per file per worktree, not per access.

## 3. Risk table

| Risk | Likelihood | Mitigation |
| --- | --- | --- |
| FPE RPC lands ≥ 1 ms (above pessimistic band) | Medium | Measure before wiring the CLI. Don't ship `--virtual` until verified. |
| `git status` perf on FPE domain is unacceptable | Medium–high | Test with `core.checkStat=minimal` (already set by gh-wt) and `core.fsmonitor`. If still bad, add a flag warning users off from full-tree tooling on virtual worktrees. |
| FPE domain teardown leaves sandbox cruft | Low | `NSFileProviderManager.remove(domain:)` handles it; pair with `sudo rm -rf ~/Library/Application\ Support/FileProvider/*` escape hatch in `gh wt gc`. |
| Xcode / SourceKit-LSP pages the whole tree | High | Document that `--virtual` disables Xcode-style indexing or that it's pay-once. |
| Distribution complexity (code signing) | High | Users build-from-source with their own cert, or we ship a signed `.pkg` via GitHub Releases once proven. |

## 4. Go/no-go gates

**Gate 1 — build the extension, measure real round trip.**
Produce a signed dev-cert `.appex`, register a domain pointing at a
real gh-wt reference, time 1 000 `open(2)` calls. This is the
single-digit days' worth of work to resolve the remaining uncertainty.

- **If measured round trip ≤ 400 µs** → proceed to Gate 2.
- **If 400 µs – 1 ms** → proceed to Gate 2 but warn about
  full-tree workflows in the README.
- **If > 1 ms** → stop. At that rate the full-tree pain is too
  big; focus instead on the already-identified wins (parallel
  clonefile, stat-correct prebuilt index, `checkout-index --prefix`).

**Gate 2 — `git status` / `git grep` sanity check.**
On a materialised-in-parts FPE domain (say 1 000 of 174 k files
touched), time `git status` and `git grep`. If either exceeds 5× the
same command on a materialised worktree, stop.

**Gate 3 — CLI integration scope.**
If Gates 1 and 2 pass, wire `gh wt add --virtual`. Default remains
APFS clonefile until users opt in per-invocation or via config.

## 5. What the measurements *didn't* show but matter

- **Thermal / sustained load.** All measurements are < 30 s bursts on
  an idle Mac. A real editor session on battery power will throttle
  and shift the curves; we haven't characterised that.
- **`fileproviderd` cold start.** First-ever access to a domain after
  boot triggers daemon initialisation; this is a one-time cost that
  adds 100 ms–1 s to the first `open` call per boot. Amortises to
  nothing in practice but is noticeable in micro-benchmarks.
- **Concurrent domain limits.** We don't know if macOS caps the
  number of active FPE domains (e.g. Dropbox + iCloud + gh-wt × N).
  Worth checking before encouraging users to keep dozens of virtual
  worktrees open.

## 6. Reproducibility

```sh
# kernel floor (no Swift, no FPE)
bash scripts/benchmark/fpe_firsttouch_floor.sh

# Swift-side floor (requires swift 6.0+)
cd macos && swift build -c release
./.build/release/FirstTouchBench /tmp/ghwt-fpe-floor/src-16 /tmp/ft-out 1000

# resulting TSV
cat scripts/benchmark/results/fpe_firsttouch_floor.tsv
```

Raw results from the 2026-04-22 run are committed at
`scripts/benchmark/results/fpe_firsttouch_floor.tsv`.
