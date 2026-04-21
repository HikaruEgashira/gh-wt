# File Provider Extension (macOS, design)

**Status:** design + scaffolding only. No shipped binary. Not wired
into `gh wt add` yet.

## 1. Why

`docs/benchmark.md` §3 establishes the floor of the shell + APFS
approach: warm `add` cannot go below ~30 s at linux/llvm scale because
`clonefile(2)` is kernel-bound and must touch every inode + dirent. The
only way to beat this is to **stop materialising files up front** and
let the filesystem fault them in on demand.

macOS ships that primitive as the **File Provider Extension**
(`FileProvider.framework`, introduced in macOS 11 for general use,
matured in 12+): a sanctioned, signed user-space extension mechanism
that lets a daemon back a mount point with lazy content. The same API
powers iCloud Drive, Dropbox, and similar tools.

Target: **O(1) worktree creation** regardless of tree size. The first
`open(2)` on a file costs one materialisation (read from the cached
reference tree via `clonefile(2)` of a single file, not the whole tree);
every subsequent `open(2)` is a regular APFS file. Worktree destruction
is O(1): unregister the domain.

## 2. API sketch

File Provider exposes a **domain** — a rooted namespace under
`~/Library/CloudStorage/<domain-id>/` (macOS ≥ 13 default;
user-visible path) — backed by an **extension** that answers queries
from the FPE daemon (`fileproviderd`).

Two supported modes; we pick the **replicated** one:

| Mode | When the file is on disk | Good for |
| --- | --- | --- |
| `NSFileProviderExtension` (non-replicated) | On-demand, user-triggered | cloud drives that stream very large trees |
| `NSFileProviderReplicatedExtension` | Fully materialised in extension's storage, but enumeration and updates are deltas through FPE | git-adjacent workloads where tools stat/read files constantly |

Replicated is closer to what git needs (stat-heavy workloads; diff,
status, grep). The extension's on-disk storage IS the cache ref (no
second copy). Materialisation per file is a `clonefile(2)` from the
shared reference into the extension's per-domain sandbox — first-touch
latency ≈ microseconds, not seconds.

Key types:

- `NSFileProviderReplicatedExtension` — root class of our extension.
- `NSFileProviderDomain` — one per worktree; created from the `gh-wt`
  CLI when the user runs `gh wt add --virtual <branch>`.
- `NSFileProviderManager.add(domain:)` / `.remove(domain:)` — CLI-side
  lifecycle.
- `NSFileProviderItem` — our implementation resolves each item from
  the cached reference tree (`build_reference` output) and the linked
  worktree's `.git` pointer.
- `Enumerator` — asked by FPE to stream children of a directory; we
  walk the reference subtree.

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│            ~/Library/CloudStorage/gh-wt-<sid>/               │  ← user sees a
│            (domain root, virtual dir)                        │    normal dir
└──┬────────────────────────────────────────────────────────┬──┘
   │                                                        │
   │ VFS (fileproviderd)                                    │
   ▼                                                        ▼
┌─────────────────────────┐          ┌─────────────────────────────┐
│ gh-wt FileProvider      │          │ git (reads files, runs      │
│ Extension (Swift, this  │          │  diff/status/grep)          │
│ scaffold)               │          │                             │
│                         │          └─────────────────────────────┘
│  enumerate()   ─────────┤
│  fetchContents() ───────┤
│  createItem()  ─────────┤
└──┬──────────────────────┘
   │ backed by
   ▼
┌──────────────────────────────────────────────────────────────┐
│   ~/.cache/gh-wt/<repo-id>/ref/<tree-sha>/                   │
│   (shared reference tree, built by gh wt add)                │
└──────────────────────────────────────────────────────────────┘
```

The extension acts as a **thin adapter** between FPE and the existing
reference cache. No new persistence layer, no mirror; the reference IS
the source of truth. Writes go to per-domain upper storage (File
Provider's `userVisibleURL`); they never leak back into the reference.

## 4. Lifecycle

### 4.1 `gh wt add --virtual <branch>` (opt-in path)

1. Resolve `tree_sha` + ensure the reference is built (same as today).
2. `NSFileProviderDomain` is created with `identifier = "gh-wt-<sid>"`
   and `displayName = "<branch> (gh-wt)"`.
3. `NSFileProviderManager.add(domain:)` registers it; the domain root
   appears under `~/Library/CloudStorage/gh-wt-<sid>/`.
4. `git worktree add --no-checkout <domain-root>/ <branch>` is run from
   the main repo (the FPE domain root is a real path, just lazily
   populated).
5. Write `.gh-wt-ref` pointer + configure worktree stats, as today.

No `cp -cRp` and no full tree materialisation.

### 4.2 First `open(2)` on a file

1. Kernel sends a `fetchContents` RPC to the extension.
2. Extension looks up the path inside the reference tree, `clonefile(2)`s
   the single file into the domain's storage, returns the URL.
3. Subsequent opens hit the materialised copy; no RPC.

### 4.3 Writes

- Writing to a materialised file is a regular APFS write. CoW triggers
  as normal (block-level); the reference stays intact.
- The extension is notified via `itemChanged`, which it records in a
  per-domain upper directory. `gh wt remove` discards both.

### 4.4 `gh wt remove <domain>`

1. `git worktree remove --force <domain-root>` for git bookkeeping.
2. `NSFileProviderManager.remove(domain:)` — FPE tears down the mount
   and the domain's storage. **O(1).** No per-file `unlink(2)` storm.

## 5. git interaction

Git mostly doesn't care that files are virtual — it `open(2)`s them
and reads. Materialisation happens on demand. Hot-path concerns:

- **`git status` walks the whole index.** FPE `stat(2)` is served
  locally without RPC for materialised items and via a cheap
  enumeration for virtual ones. With `core.checkStat = minimal` (which
  gh-wt already sets in `configure_worktree_stat`) this should stay
  fast.
- **`git grep` touches every file.** This is the worst case for
  on-demand materialisation: it causes every file to be populated.
  Measure and, if bad, document that `git grep --cached` is the fast
  path. This is the single biggest risk to UX.
- **`git diff` against working tree** — reads files only where the
  index says they differ. Normally fine.

## 6. Build & distribution

This is where "not yet shipped" bites. File Provider Extensions are
**sandboxed appex bundles** that must be:

1. Signed with a Developer ID certificate.
2. Packaged inside a host `.app` that `NSFileProviderManager` can
   locate at runtime.
3. Entitled with `com.apple.developer.fileprovider.managed-domain`.

For an open-source CLI this is awkward:

- No way to ship as a single binary; the `.app` bundle has to install
  somewhere. `/Applications/gh-wt-file-provider.app` is conventional.
- `codesign` requires a developer cert. Anonymous builds won't load.
- Users without the `.app` installed fall back to the plain APFS
  clonefile path — no regression for today's usage.

MVP plan:

1. Scaffold Swift Package (this commit): library target plus an
   `.app`-wrapping Xcode project generated via SwiftPM's `generate-xcodeproj`
   (deprecated but the simplest path pre-Xcode-integration).
2. Local testing: use a self-signed dev cert + `sudo spctl`
   disable-assessment to sideload during development.
3. Distribution: either ship as a signed `.pkg` via GitHub Releases
   or document the build-from-source path for users with their own
   developer cert. **Decided later.**

## 7. Scope boundaries for v0

**In**:
- Skeleton Swift code that compiles.
- A design doc (this file).
- A `macos/README.md` with build instructions (see separate file).
- No integration with `gh wt` yet — that's a follow-up PR.

**Out (deferred)**:
- Actual signing / notarisation pipeline.
- CI build of the extension.
- Integration into `cmd_add` as `--virtual` flag.
- Benchmarks vs APFS clonefile — the whole point is to replace warm
  30 s with sub-second, but we need a working build first.

## 8. Open questions

- **Replicated vs non-replicated.** Replicated is what I recommend; the
  non-replicated mode is for truly streaming workloads and adds more
  latency per open. Could be revisited after first benchmarks.
- **One domain per worktree, or one global domain with sub-trees?**
  Current design: one per worktree (clean lifecycle via
  `remove(domain:)`, O(1) teardown). Global domain would complicate gc.
- **Interaction with Xcode's SourceKit-LSP indexing.** Indexing might
  page the whole tree at a time; worth measuring on llvm-project.
- **macOS version floor.** `NSFileProviderReplicatedExtension` is
  macOS 11+ user-space API; declared entitlements for unmanaged domains
  require macOS 13+. Target: macOS 13+.

## 9. Next steps

1. Verify the skeleton builds (blocked: needs Xcode + developer cert).
2. Stand up a test harness that hosts the extension, registers a
   domain, and fetches one file through FPE. Measure first-touch
   latency.
3. Decide whether to continue (fast first-touch, tolerable
   `git grep`) or abandon (either is prohibitive).
4. Only then: wire into `gh wt add --virtual`.

If step 2 shows first-touch latency > 100 ms / file, the whole
approach is unlikely to be competitive with parallel clonefile on
warm `add`. If `git grep` on the full tree is more than 2× slower
than baseline, most users won't adopt the `--virtual` flag.
