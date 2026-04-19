<div align="center">
    <h2 align="center">gh-wt</h2>
    <small align="center">OverlayFS-backed worktree sessions for git</small>
</div>

<h3 align="center">
🔹<a  href="https://github.com/HikaruEgashira/gh-wt/issues">Report Bug</a> &nbsp; &nbsp;
🔹<a  href="https://github.com/HikaruEgashira/gh-wt/issues">Request Feature</a>
</h3>

`gh wt` creates a `git worktree` whose working tree is an overlay mount: a
shared, immutable *reference* (read-only lower) plus a per-session *upper*
where writes go. A session starts in tens of milliseconds, and N sessions cost
`1 × repo_size + Σ per-session diffs` on disk.

The overlay backend is platform-specific: **OverlayFS** on Linux and a
**FSKit System Extension** on macOS. Both expose identical semantics; see
`tests/parity/` for the cross-checks.

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

v0 has **one** implementation path per platform — no fallbacks. Pick the
matching column for your host:

| Requirement                      | Linux                              | macOS                                                   |
| -------------------------------- | ---------------------------------- | ------------------------------------------------------- |
| OS version                       | Kernel 5.11+                       | macOS 26 (Tahoe) or newer                               |
| Overlay primitive                | `overlay` in `/proc/filesystems`   | `gh-wt-overlay` FSKit System Extension activated        |
| Mount privilege                  | root or passwordless `sudo`        | n/a (FSKit runs in the user session)                    |
| Repo                             | non-bare git repo                  | non-bare git repo                                       |
| Submodules                       | rejected (deferred to v1)          | rejected (deferred to v1)                               |

macOS users must install and activate the host app once — see
[`macos/README.md`](macos/README.md). After that, `gh wt doctor` should
report all green.

Windows, older Linux without OverlayFS, older macOS, and container
environments without overlay primitives are **not supported** in v0.

## Architecture

```text
~/.cache/gh-wt/<repo-id>/
├── ref/<tree-sha>/       # raw working tree at a commit tree SHA (immutable)
└── sessions/<sid>/
    ├── upper/            # per-session CoW layer (holds .git, user writes)
    └── workdir/          # overlayfs scratch (Linux only)

<mountpoint>/             # overlay of lower=ref/<tree-sha>, upper=session upper
```

`gh wt add` resolves the branch's commit tree SHA, materialises the reference
once via `git archive | tar` if missing, registers a linked worktree with
`git worktree add --no-checkout`, moves the generated `.git` pointer into the
session upper, and mounts the overlay at the mountpoint. `core.checkStat=minimal`
and `core.trustctime=false` are set on the linked worktree to survive overlay
copy-up inode changes.

The overlay primitive is selected by `lib/overlay.sh`:

- **Linux**: `mount -t overlay overlay -o lowerdir=…,upperdir=…,workdir=…`
- **macOS**: `gh-wt-mount-overlay mount --lower … --upper … --mountpoint …`,
  which forwards to the `gh-wt-overlay` FSKit System Extension. Whiteouts
  and opaque directories are encoded as xattrs on the upper layer; see
  [`macos/README.md`](macos/README.md) for the full semantics.

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
