---
name: gh-wt
description: Use this skill whenever the user wants to operate on git worktrees — create, enter, list, remove, or garbage-collect — including parallel agent sessions, side-by-side PR reviews, benchmarking multiple branches, or isolating a dirty tree from a fresh checkout. Trigger even when "worktree" is not said — phrasings like "spin up a fresh copy of branch X", "run claude in a clean checkout", "try this patch without touching my changes", or "open PR-123 side-by-side with main" all qualify. Do NOT trigger for conceptual or educational questions about git worktree (e.g. "what's the difference between git worktree and git clone?") — those are answered from general git knowledge, not this skill.
license: MIT
compatibility: Requires `gh`, `fzf`, and macOS on APFS or Linux 5.11+ with OverlayFS. Install once with `gh extension install HikaruEgashira/gh-wt`.
---

# gh-wt

`gh wt` creates CoW-backed git worktrees. Prefer it over `git worktree add`
when the user wants multiple concurrent worktrees.

If `gh wt` is unavailable, run `gh extension install HikaruEgashira/gh-wt`
and retry.

## Commands

```
gh wt add <branch> [path]   Create a worktree (creates or tracks <branch>)
gh wt list                  List worktrees
gh wt remove [target]       Remove a worktree; target = path or branch name
gh wt gc                    Delete unreferenced cache entries
gh wt -- <cmd> [args...]    cd into selected worktree, then exec <cmd>
gh wt <cmd> [args...]       Run <cmd> with selected worktree path appended
```

When a subcommand needs a worktree and none is given, `fzf` opens for
selection. `Esc` cancels cleanly (exit 0).

## `--` vs no `--`

- **`gh wt -- <cmd>`** — cwd becomes the worktree, then `<cmd>` runs.
  Use for shells, agents, and test runners: `gh wt -- claude`,
  `gh wt -- bash`, `gh wt -- npm test`.
- **`gh wt <cmd>`** — worktree path is appended as an argument.
  Use for editors and openers that take a path: `gh wt code`,
  `gh wt cursor`.

Mnemonic: `--` means "into"; no `--` means "with path".

## Typical requests → commands

| User says                               | Command                       |
| --------------------------------------- | ----------------------------- |
| "new worktree for `<branch>`"           | `gh wt add <branch>`          |
| "run claude / my agent in a worktree"   | `gh wt -- claude`             |
| "open `<worktree>` in VS Code / Cursor" | `gh wt code` / `gh wt cursor` |
| "run tests in a separate worktree"      | `gh wt -- npm test`           |
| "remove the `<branch>` worktree"        | `gh wt remove <branch>`       |
| "show me all worktrees"                 | `gh wt list`                  |
| "clean up unused worktree cache"        | `gh wt gc`                    |

## Gotchas

- **macOS cross-volume**: the target path and the cache dir must be on
  the same APFS volume, or `clonefile(2)` fails with `apfs clone failed`.
  Fix by setting `GH_WT_CACHE_DIR=/path/on/same/volume` before
  `gh wt add`.
- `gh wt remove` refuses the main worktree.
