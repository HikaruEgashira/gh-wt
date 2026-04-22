# Architecture

`gh wt add <branch>` creates a CoW-shared git worktree. A shared read-only
*reference* holds the committed tree contents; the worktree itself is either
an OverlayFS mount on top of that reference (Linux) or an APFS clonefile(2)
copy of it (macOS). The physical repo is never duplicated.

## Cache layout

```text
~/.cache/gh-wt/<repo-id>/
├── ref/<tree-sha>/       # raw working tree at a commit tree SHA (immutable)
├── ref/<tree-sha>.index  # stat-correct git index for the reference above
└── sessions/<sid>/       # overlayfs only: per-worktree upper + workdir
    ├── upper/
    └── workdir/
```

- `<repo-id>` = SHA-1 of the main repo's absolute path.
- `<tree-sha>` = `git rev-parse <branch>^{tree}`. Worktrees whose branch
  heads map to the same tree share the same reference automatically.
- `<tree-sha>.index` = prebuilt git index whose stat cache matches the
  reference's extracted files. Dropped into the linked worktree's
  `index` at `add` time to skip the ~14 s `git reset --mixed HEAD`
  that would otherwise rehash every file to repopulate the stat cache.
- `<sid>` = basename of the linked-worktree gitdir, which git generates
  from the branch name (with collision suffixing).

References are never mutated after creation — if a branch moves, a new
reference is materialised lazily on the next `gh wt add`.

## Platform auto-selection

`lib/backend.sh::resolve_backend` picks a strategy from host capabilities —
there is no env var, no config file, and no `set-` subcommand. The tool
picks what works.

| Platform     | Strategy                             | Kernel / FS call   |
| ------------ | ------------------------------------ | ------------------ |
| Linux 5.11+  | OverlayFS mount                      | `mount -t overlay` |
| macOS (APFS) | `cp -c` clonefile into the worktree  | `clonefile(2)`     |
| other        | Plain `git worktree add`, no sharing | —                  |

`lib/worktree.sh::cmd_add` branches on the resolved strategy; the three
paths share the reference-cache build step (`git checkout-index` into a
disposable index built from the target tree).

### Preflight order

All three backends run the same preflight sequence before touching disk:

1. Resolve branch kind (`local` / `remote` / `new`).
2. If `new`, require an opt-in (`--new` flag, `GH_WT_ASSUME_NEW=1`, or a
   TTY `[y/N]` confirmation) — otherwise a typo like `mian` would
   silently create a new branch from HEAD.
3. If `local`, reject when the branch is already checked out in another
   worktree (`git worktree list --porcelain` → `branch refs/heads/<b>`).
4. Canonicalise the requested mountpoint and reject if it already exists.
5. Only now create a missing `remote`/`new` branch.
6. Build the reference cache (cold only) and materialise the worktree.

Steps 2–4 are intentionally ahead of step 6: a failed run must not leave
a half-built reference under `<cache>/ref/<tree-sha>/` or a stray branch
for a typo'd name. The case-collision scan (see below) runs inside step
6 because it needs the tree SHA.

### Linux — OverlayFS

```bash
mount -t overlay overlay \
  -o lowerdir=$LOWER,upperdir=$UPPER,workdir=$WORK \
  $MNT
```

Needs root or passwordless `sudo`. The session's `.git` pointer is moved
into `upper/` before mount so it survives the overlay and remains writable.

### macOS — APFS clonefile

```bash
find $REF_PATH -mindepth 1 -maxdepth 1 -print0 \
  | xargs -0 -n 1 -P 4 -I{} cp -cRp '{}' $MNT/
```

`cp -c` issues `clonefile(2)`, which creates CoW links at the block level.
Files share blocks with the reference until modified; modifying a file
triggers CoW only for the diverging extents.

Top-level entries are cloned in parallel because APFS's spine-lock
contention is per-parent-dir; spreading work across distinct subtrees
gives ~1.7× warm-add speedup at P=4 on Apple Silicon (P-core count is
the empirical sweet spot — past it, contention dominates and throughput
regresses). Override with `GH_WT_CLONE_PARALLELISM=N` (set to 1 to
serialise for debugging or single-core hosts).

### Case-insensitive filesystem guard

APFS volumes are case-insensitive by default. Trees that contain paths
differing only in case (`xt_CONNMARK.h` and `xt_connmark.h` in the linux
kernel, ~13 such pairs) cannot be losslessly materialised onto a
case-insensitive volume — the second write silently overwrites the
first and every worktree cloned from the resulting reference inherits
the corruption. `git checkout-index` (used to extract the tree, see
below) does not raise an error on such overwrites either, so the guard
has to be up-front.

`build_reference` probes the cache volume for case-insensitivity (one
file create + one stat) and, if positive, scans the tree for case-fold
duplicates before extraction. Any duplicates → `die` with the offending
paths. Case-sensitive volumes (Linux ext4/btrfs/xfs, opt-in
case-sensitive APFS) skip the scan entirely.

Extraction itself uses `git read-tree` into a disposable index
(`GIT_INDEX_FILE=<tmp>.idx`) followed by
`git checkout-index --all --prefix=<tmp>/`. Compared with the earlier
`git archive <tree> | tar -x -C <tmp>` pipeline this skips the
pack-format round-trip (git builds a tar stream, tar parses it back
into files) and writes exactly the path names and modes recorded in
the tree, including the executable bit and symlink entries (via
`core.symlinks`).

Semantics vs OverlayFS:
- No separate upper/workdir — the worktree is the only materialised copy.
- No mount state: removal is a plain `git worktree remove`.
- The reference it cloned from is recorded in `<worktree>/.gh-wt-ref` so
  `gh wt gc` can tell which references are still pinned. The marker file
  is added to the worktree's private `info/exclude` so it doesn't show up
  in `git status`.
- After clonefile, the prebuilt `<tree-sha>.index` sidecar is copied into
  the linked worktree's `index` path (under `.git/worktrees/<sid>/`) so
  `git status` finds a valid stat cache immediately — no post-clonefile
  `git reset --mixed HEAD` is needed. `core.checkStat=minimal` +
  `core.trustctime=false` (set via `configure_worktree_stat`) tell git
  to compare only `mtime.sec` and `size`, both of which `cp -cRp`
  preserves exactly.

### Fallback — plain `git worktree`

When neither OverlayFS nor APFS clonefile is available, `cmd_add` runs
`git worktree add --no-checkout` then kicks off `git reset --hard HEAD`
in the background so the caller returns immediately. Progress lands in
`.gh-wt-checkout.log` inside the new worktree.

## `gh wt list`

Thin wrapper around `git worktree list`. gh-wt doesn't maintain its own
index — every worktree is a real linked worktree.

## `gh wt remove`

1. Select a worktree (see "Worktree selection" below).
2. OverlayFS: check no processes hold files open (`fuser`), unmount.
3. `git worktree remove --force`.
4. OverlayFS: `rm -rf <session dir>`.

References are not removed — that's `gh wt gc`'s job.

## Worktree selection

`gh wt remove`, `gh wt -- <cmd>`, and `gh wt <cmd>` all need to pick a
worktree. The selection path has three layers (in order of preference):

1. **Explicit target**. `gh wt --at <branch|path> ...` (or the
   positional form on `remove`) bypasses fzf entirely and resolves
   against `git worktree list --porcelain` via `resolve_worktree_arg`.
   The argument may be a registered worktree path or the checked-out
   branch name; mismatches die with "no registered worktree matches".
2. **`--select-1` short-circuit**. fzf is invoked with `--select-1
   --exit-0`, so when there's only one candidate (the usual single-dev
   case) it returns immediately without opening `/dev/tty`.
3. **Non-interactive guard**. `GH_WT_NONINTERACTIVE=1` refuses to spawn
   fzf at all and exits 2 with the candidate list on stderr. Intended
   for CI, `nohup`, and agent-driven shells (e.g. Claude Code) where
   `/dev/tty` is not available; `--at` is usually the better fix, this
   variable is the debug-visibility lever.

## `gh wt gc`

Walks `<cache>/ref/`, diffs against currently-live references, and removes
the rest. "Live" means:

- OverlayFS: appears as a `lowerdir=` in `/proc/mounts`.
- APFS: appears in some worktree's `.gh-wt-ref` sidecar.

Protection from git's own GC comes from the linked-worktree machinery —
any commit reachable from a live worktree stays alive in the main repo.

## Design invariants

- **Platform auto-selects**. No user-facing "backend" knob. The best
  strategy for the host is picked and that's what runs.
- **Git-native**. Worktrees are real linked worktrees. No custom `.git`
  plumbing, no alternates (which would create GC hazards).
- **Reference immutability**. References are write-once per tree SHA.
  Branches that advance create new references on the next `gh wt add`;
  old references are collected by `gh wt gc` when no worktree pins them.
- **No dependency cache layer**. Block-level sharing (OverlayFS lower or
  APFS clone) is the only sharing mechanism. Per-worktree dependency
  directories are intentional — route heavy build artefacts to scratch
  via env vars if you care.
