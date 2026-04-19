<div align="center">
    <h2 align="center">gh-wt</h2>
    <small align="center">Explainable, overlay-based worktree management</small>
</div>

<h3 align="center">
<a href="https://github.com/HikaruEgashira/gh-wt/issues">Report Bug</a> &nbsp;&nbsp;
<a href="https://github.com/HikaruEgashira/gh-wt/issues">Request Feature</a>
</h3>

## What

`gh wt add <branch>` creates a worktree backed by a **copy-on-write overlay**:
a shared read-only reference (the branch's tree) plus a per-session writable
upper layer. No physical duplication of the working tree, and N sessions
consume `1 × repo_size + Σ per-session diff` on disk.

- **Phase 1 (Linux)**: uses the kernel's OverlayFS directly.
- **Phase 2 (macOS)**: FSKit System Extension with OverlayFS-equivalent
  semantics (separate distribution).

See [`docs/design-v0.md`](docs/design-v0.md) for the full design rationale.

## Install

```bash
gh extension install HikaruEgashira/gh-wt
```

## Usage

```bash
# Create an overlay worktree for a branch
gh wt add feature-branch

# List worktrees in the current repository
gh wt list

# Remove a worktree (interactive via fzf) and its overlay upper layer
gh wt remove

# Open a worktree in VS Code (passes the path as an argument)
gh wt code

# Run a command inside the selected worktree directory
gh wt -- claude
gh wt -- git status

# Garbage-collect overlay references that no live session uses
gh wt gc

# Check whether overlay is available in the current environment
gh wt doctor
```

## Commands

| Command | Description |
|---|---|
| `gh wt add <branch> [path]` | Create an overlay session |
| `gh wt list` | Wrapper for `git worktree list` |
| `gh wt remove` | fzf pick + overlay umount + `git worktree remove` |
| `gh wt gc` | Remove reference directories not used by any live overlay |
| `gh wt doctor` | Report overlay / platform readiness |
| `gh wt -- <cmd>` | fzf pick + run `<cmd>` in the session dir |
| `gh wt <cmd>` | fzf pick + run `<cmd> <path>` |

## How it is laid out

```
~/.cache/gh-wt/<repo-id>/
├── ref/<tree-sha>/       # shared, immutable: one per commit tree
└── sessions/<sid>/
    ├── upper/            # per-session writable layer (incl. .git)
    └── workdir/          # overlay scratch (Linux only)
```

`<repo-id>` is the SHA-1 of the absolute path of the main repository.
`<tree-sha>` is `git rev-parse <branch>^{tree}`, so sessions that start from
the same tree automatically share the same reference. `<sid>` is derived from
the mountpoint basename.

The main repository is never modified beyond the normal `git worktree add`
metadata it already writes under `.git/worktrees/<sid>/`.

## Requirements

### Linux

- Kernel with OverlayFS (5.11+ recommended)
- `CAP_SYS_ADMIN` (root or an equivalent capability) for `mount(2)`
- `fzf`, `git`

### macOS

Phase 2. Requires the `gh-wt-overlay` FSKit System Extension, which is
distributed separately (not yet released). macOS 26+ is recommended.

## Dependency caching

There is no separate dependency-caching feature. The overlay's lower layer
already shares every file in the branch's tree across all sessions. Anything
you `npm install` / `cargo build` inside a session is written to that
session's upper layer and stays isolated there. To keep build artefacts out
of the upper layer, point build tools at a scratch directory, e.g.:

```bash
export CARGO_TARGET_DIR="$HOME/.cache/cargo-target/$USER"
```

## Acknowledgements

- [`gh-q`](https://github.com/HikaruEgashira/gh-q): Quick repository
  navigation

```bash
gh q                    # select repository
gh q --                 # change directory
gh wt add feature/new   # create overlay worktree
gh wt -- codex          # open worktree in Codex
```
