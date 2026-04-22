<h2 align="center">
    <p align="center">gh-wt</p>
</h2>

<h3 align="center">
🔹<a href="https://github.com/HikaruEgashira/gh-wt/issues">Report Bug</a> &nbsp; &nbsp;
🔹<a href="https://github.com/HikaruEgashira/gh-wt/issues">Request Feature</a>
</h3>

Fast and Ligtweight CoW-backed git worktree sessions . Linux uses OverlayFS,
macOS uses APFS clonefile(2).

```
disk used (GiB) — k same-tree worktrees of the Linux kernel (1.77 GiB, 93k files)

18 |                                      ●                    git worktree add  (O(N))
   |                                   ●
15 |                                 /
   |                              /
12 |                           /
   |                        /
 9 |                    ●
   |                  /
 6 |               /
   |            /
 3 |         ●
   |    ●           ·           ·          ·          ·          ●  gh wt add    (≈const)
 0 ●─────●─────────●─────────────────────●─────────●─────────●
   0     1   2     5            10            15           20    k (# worktrees)
```

At k = 10 worktrees gh-wt uses **~8×** less disk; at k = 20, **~13×**.
Full methodology and raw data: [`docs/benchmark.md`](./docs/benchmark.md).

## Installation

```bash
gh extension install HikaruEgashira/gh-wt
```

### Install as an agent skill

Teach a skills-compatible agent (Claude Code, Copilot, Cursor, Codex, Gemini
CLI, ...) how to drive `gh wt`:

```bash
gh skill install HikaruEgashira/gh-wt gh-wt
```

The skill in [`skills/gh-wt/`](./skills/gh-wt/SKILL.md) follows the
[Agent Skills specification](https://agentskills.io/specification).
Requires `gh` v2.90.0+.

## Usage

```bash
$ gh wt --help
Usage:
  gh wt list                ... List worktrees
  gh wt add <branch> [path] ... Add a worktree
  gh wt remove              ... Remove a worktree (interactive)
  gh wt gc                  ... Delete unreferenced cache entries
  gh wt *your_command*      ... Search via fzf and run the command
```

### Examples

```bash
# Create a worktree for a branch
gh wt add feature-branch

# Remove a worktree (interactive)
gh wt remove

# Open a worktree in VS Code
gh wt code

# Run a command inside a selected worktree
gh wt -- claude
```

## Requirements

- [GitHub CLI](https://cli.github.com/)
- [fzf](https://github.com/junegunn/fzf)
- Linux (kernel 5.11+) or macOS (APFS)

## Related

- [gh-q](https://github.com/HikaruEgashira/gh-q) - ghq-like repository management for GitHub CLI
