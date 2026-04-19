# Architecture

`gh wt add <branch>` creates a **CoW overlay worktree**: a shared
read-only *reference* (lower) plus a per-session writable *upper*. The
physical repo is never duplicated; overlay creation is a cheap mount.

## Cache layout

```text
~/.cache/gh-wt/<repo-id>/
├── ref/<tree-sha>/       # raw working tree at a commit tree SHA (immutable)
└── sessions/<sid>/
    ├── upper/            # per-session CoW layer (holds .git, user writes)
    └── workdir/          # overlayfs scratch (Linux only)

<mountpoint>/             # overlay of lower=ref/<tree-sha>, upper=session upper
```

- `<repo-id>` = SHA-1 of the main repo's absolute path.
- `<tree-sha>` = `git rev-parse <branch>^{tree}`. Sessions whose branch
  heads map to the same tree share the same reference automatically.
- `<sid>` = basename of the linked-worktree gitdir, which git generates
  from the branch name (with collision suffixing).

References are never mutated after creation — if a branch moves, a new
reference is materialised lazily on the next `gh wt add`.

## `gh wt add` flow

1. Resolve the branch's commit tree SHA.
2. If `<cache>/ref/<tree-sha>/` doesn't exist, materialise it:
   `git archive <branch> | tar -x -C <ref-path>`. No `.git` goes in.
3. Create `<cache>/sessions/<sid>/{upper,workdir}`.
4. `git worktree add --no-checkout <mountpoint> <branch>` — this
   registers a linked worktree with git and writes a `.git` pointer
   file at the mountpoint.
5. Move that `.git` file into the session upper (so it survives the
   overlay mount sitting on top of it).
6. `overlay_mount lower=<ref> upper=<session upper> workdir=<scratch>
   mountpoint=<mountpoint>`.
7. `git config --worktree core.checkStat=minimal` and
   `core.trustctime=false` on the linked worktree so git doesn't
   get confused by inode changes during copy-up.
8. `git update-index --refresh`.

On a warm cache, steps 3–8 take ~50–100 ms on Linux and ~200–400 ms on
macOS (FSKit is userspace).

## Overlay backend

Backend selection is driven by `lib/backend.sh`. Resolution order is
`GH_WT_BACKEND` env var, then the XDG config file
(`${XDG_CONFIG_HOME:-~/.config}/gh-wt/config` — written by
`gh wt set-backend`), then `auto`. Supported values:

| backend     | OS       | helper binary                 |
| ----------- | -------- | ----------------------------- |
| `overlayfs` | Linux    | kernel `mount -t overlay`     |
| `fskit`     | macOS 26+| `gh-wt-mount-overlay` (XPC → FSKit) |
| `macfuse`   | macOS    | `gh-wt-mount-overlay-fuse` (libfuse)|
| `none`      | any      | no overlay — plain `git worktree add` |

`auto` on macOS prefers `fskit` when the helper is present and the host is
macOS 26+; otherwise it falls back to `macfuse`. Platform differences live
entirely in `lib/overlay.sh` (backend dispatch) and `lib/env.sh`
(per-backend preflight); everything above is backend-neutral.

`none` short-circuits the cache/session machinery in `lib/worktree.sh` —
it skips reference materialisation, upper/workdir allocation, and mount —
so it works wherever `git` does, at the cost of a full checkout per
worktree. Use it as the portable fallback or on CI runners where the
kernel helper is unavailable.

### Linux — kernel OverlayFS

```bash
mount -t overlay overlay \
  -o lowerdir=$LOWER,upperdir=$UPPER,workdir=$WORK \
  $MNT
```

Needs root or passwordless `sudo`. OverlayFS handles whiteouts
(character devices) and opaque dirs (`trusted.overlay.opaque=y` xattr)
natively.

### macOS — FSKit System Extension

```
gh wt add <branch>
   └── overlay_mount lower upper work mountpoint        (lib/overlay.sh)
         └── gh-wt-mount-overlay mount …                (Swift CLI)
               └── /usr/sbin/fskit_load --bundle-id …   (macOS 26)
                     └── fskitd loads OverlayFileSystem (FSKit extn)
                           └── extn calls Overlay(lower:upper:)
```

Implementation lives under `macos/` as a Swift Package:

| Path                                | Role                                                  |
| ----------------------------------- | ----------------------------------------------------- |
| `Sources/OverlayCore/`              | Pure-Swift overlay semantics.                         |
| `Sources/GhWtOverlayExtension/`     | FSKit `FSUnaryFileSystem` adapter around OverlayCore. |
| `Sources/GhWtMountOverlay/`         | `gh-wt-mount-overlay` CLI.                            |
| `App/`                              | Host app bundle (`GhWtOverlay.app`).                  |

The Swift extension is a thin adapter — all semantic decisions live in
`OverlayCore` so the same code is exercised by unit tests and by the
Linux/macOS parity harness.

### Whiteout & opaque encoding (macOS)

OverlayCore encodes deletions in the upper layer as xattrs on plain
files, avoiding character-device whiteouts (which need root):

| Marker     | xattr name                  | Target              | Meaning                                 |
| ---------- | --------------------------- | ------------------- | --------------------------------------- |
| Whiteout   | `com.github.gh-wt.whiteout` | empty regular file  | Hides a lower entry of the same name.   |
| Opaque dir | `com.github.gh-wt.opaque`   | upper directory     | Hides all of lower's contents below it. |

The upper dir is otherwise a normal POSIX tree — `cp -R` and re-mount
elsewhere is safe.

### Live mount registry (macOS)

macOS has no `/proc/mounts`-style way to recover the lower path of a
live overlay. `gh-wt-mount-overlay` records each mount as JSON under
`~/Library/Application Support/gh-wt-overlay/mounts/<hash>.json`. `gh
wt gc` reads those (via `gh-wt-mount-overlay list-lowers`) to know
which references are still pinned. Records are cross-checked against
`mount(8)` output and stale ones are cleaned opportunistically.

### macOS — macFUSE

```
gh wt add <branch>
   └── overlay_mount lower upper work mountpoint        (lib/overlay.sh)
         └── gh-wt-mount-overlay-fuse mount …           (libfuse CLI)
               └── libfuse → /Library/Filesystems/macfuse.fs kext
                     └── callbacks delegate to OverlayCore semantics
```

Why a separate binary (`gh-wt-mount-overlay-fuse`) rather than a `--backend
macfuse` flag on the FSKit helper: linking libfuse into the FSKit binary
would make its installability depend on macFUSE being present, defeating
the point of keeping them independent. The two helpers share `OverlayCore`
(same semantics, same test suite) but link against different host APIs.

`gh-wt-mount-overlay-fuse` must expose the same CLI contract as the FSKit
helper:

- `mount --lower L --upper U --mountpoint M`
- `unmount --mountpoint M`
- `list-lowers` — one live lower path per line
- `doctor` — exit non-zero when misconfigured

Its mount registry lives at
`~/Library/Application Support/gh-wt-overlay-fuse/mounts/<hash>.json` so
the two backends can coexist without clobbering each other.

The actual libfuse adapter (C shim + Swift wrapper around OverlayCore)
ships in a dedicated Swift target — see `docs/distribution.md` for build
instructions.

## `gh wt list`

Thin wrapper around `git worktree list` — gh-wt doesn't maintain its
own index. Every overlay session is a real linked worktree.

## `gh wt remove`

1. fzf-select a session.
2. Check no processes hold files open in the mountpoint
   (`fuser`/`lsof`).
3. Unmount the overlay.
4. `git worktree remove --force`.
5. `rm -rf <session dir>`.

Reference is *not* removed — that's `gh wt gc`'s job.

## `gh wt gc`

Walks `<cache>/ref/`, diffs against currently-live overlay lower dirs
(Linux: `/proc/mounts`; macOS: the live mount registry), and removes
references that nothing is using. Protection from git's own GC comes
from the linked-worktree machinery — any commit reachable from a live
session stays alive in the main repo.

## Design invariants

- **One overlay semantics, multiple backends**: `OverlayCore` is the single
  source of truth for merge/whiteout/copy-up behaviour. Backends
  (`overlayfs`, `fskit`, `macfuse`) are thin adapters and must not diverge
  semantically — any observable difference is a bug to be fixed in the
  adapter, not exposed as a flag. No `--overlay`/`--no-overlay`, no
  `git worktree`-only fallback. (Previously worded as "single path per
  platform"; relaxed in v0.x to allow the macFUSE adapter on older macOS.)
- **Git-native**: sessions are real linked worktrees. No custom `.git`
  plumbing, no alternates (which would create GC hazards).
- **Reference immutability**: references are write-once per tree SHA.
  Branches that advance create new references on the next `gh wt add`;
  old references are collected by `gh wt gc` when no session pins them.
- **No dependency cache layer**: overlay's lower is the only sharing
  mechanism. Per-session dependency directories are intentional — route
  heavy build artefacts to scratch via env vars if you care.

## Known gaps

- **FSKit API drift.** `OverlayVolume.swift` targets the macOS 26 FSKit
  surface. When Apple revs it, the protocol conformances/signatures
  need adjusting; OverlayCore's semantics don't change.
- **No kernel attribute cache on macOS.** FSKit doesn't yet expose
  `entry_timeout`/`attr_timeout`. Large `readdir` loops run slower than
  on Linux OverlayFS.
- **xattr passthrough.** OverlayCore doesn't yet expose user xattrs via
  FSKit's `XattrOperations`. Add when a real workload needs it.
- **Single-user activation.** FSKit extensions activate per user.
  Multi-user hosts need each user to run the activation flow once (or
  an MDM profile — see `docs/distribution.md`).
