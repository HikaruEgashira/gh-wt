<div align="center">
    <h2 align="center">gh-wt</h2>
    <small align="center">OverlayFS-backed worktree sessions for git</small>
</div>

<h3 align="center">
🔹<a  href="https://github.com/HikaruEgashira/gh-wt/issues">Report Bug</a> &nbsp; &nbsp;
🔹<a  href="https://github.com/HikaruEgashira/gh-wt/issues">Request Feature</a>
</h3>

`gh wt` creates a `git worktree` whose working tree is an OverlayFS mount: a
shared, immutable *reference* (read-only lower) plus a per-session *upper*
where writes go. A session starts in tens of milliseconds, and N sessions cost
`1 × repo_size + Σ per-session diffs` on disk.

## Install

```bash
gh extension install HikaruEgashira/gh-wt
```

## Usage

```bash
# Create an overlay-backed session for a branch
gh wt add feature-branch
gh wt add feature-branch /custom/mountpoint

# List worktrees (wraps git worktree list)
gh wt list

# Remove a session (fzf select + umount + git worktree remove + cleanup)
gh wt remove

# Delete unreferenced cache entries
gh wt gc

# fzf a session and run a command inside it
gh wt -- claude
gh wt -- git status

# fzf a session and pass its path to a command
gh wt code
```

## Requirements (v0)

v0 has **one** implementation path — no fallbacks. Hosts that don't meet these
requirements cannot run `gh wt`:

1. Linux kernel **5.11** or newer
2. `overlay` listed in `/proc/filesystems`
3. A non-bare git repository (the current directory, or a linked worktree of it)
4. Ability to call `mount(2)` — either running as root, or passwordless `sudo`
5. No submodules (a `.gitmodules` file triggers an explicit error)

macOS, Windows, older Linux, and container environments without OverlayFS are
**not supported** in v0. Submodule and non-privileged-mount support is deferred
to v1.

## Architecture

```text
~/.cache/gh-wt/<repo-id>/
├── ref/<tree-sha>/       # raw working tree at a commit tree SHA (immutable)
└── sessions/<sid>/
    ├── upper/            # per-session CoW layer (holds .git, user writes)
    └── workdir/          # overlayfs scratch

<mountpoint>/             # overlay of lower=ref/<tree-sha>, upper=session upper
```

`gh wt add` resolves the branch's commit tree SHA, materialises the reference
once via `git archive | tar` if missing, registers a linked worktree with
`git worktree add --no-checkout`, moves the generated `.git` pointer into the
session upper, and mounts the overlay at the mountpoint. `core.checkStat=minimal`
and `core.trustctime=false` are set on the linked worktree to survive overlay
copy-up inode changes.

## Notes

- `gh wt list` is a thin wrapper around `git worktree list`; gh-wt does not
  maintain a separate session index.
- Writes in a session land in that session's upper only. Dependency directories
  (e.g. `node_modules`) are **not** shared between sessions — use env vars like
  `CARGO_TARGET_DIR`, `GOCACHE`, `PIP_CACHE_DIR` to route large build artefacts
  to scratch instead of the upper.
- `gh wt gc` deletes references that no live overlay mount points at. Session
  removal already deletes that session's own upper/workdir.
- Cache location is `$XDG_CACHE_HOME`-style at `~/.cache/gh-wt/`. Override with
  `GH_WT_CACHE=/path`.

## Acknowledgements

- [`gh-q`](https://github.com/HikaruEgashira/gh-q): Quick repository navigation

```bash
gh q                    # Select repository
gh q --                 # Change directory
gh wt add feature/new   # Create new worktree
gh wt -- codex          # Open worktree in Codex
```
