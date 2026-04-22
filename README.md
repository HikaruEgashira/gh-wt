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
gh skill install HikaruEgashira/gh-wt gh-wt
```

## Usage

```bash
$ gh wt --help
Usage:
  gh wt list                            ... List worktrees
  gh wt add [--new|-b] <branch> [path]  ... Add a worktree
  gh wt remove [target]                 ... Remove a worktree
  gh wt gc                              ... Delete unreferenced cache entries
  gh wt [--at <wt>] *your_command*      ... Run a command in/with a worktree
```

`gh wt add` refuses to silently create a branch that doesn't already
exist locally or as `origin/<name>`. Pass `--new` (or `-b`) to opt into
new-branch creation from `HEAD`, or export `GH_WT_ASSUME_NEW=1` for
scripted use. On a TTY you'll get an interactive `[y/N]` prompt instead.

The fzf picker is skipped when there's only one candidate (`--select-1`),
when you pin the target with `--at <branch|path>`, or when you set
`GH_WT_NONINTERACTIVE=1` (which refuses to prompt and exits 2 with a
candidate list). This makes `gh wt` safe to call from CI, `nohup`, and
agent-driven shells (e.g. Claude Code) where `/dev/tty` is unavailable.

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

- [GitHub CLI](https://cli.github.com/) v2.90.0+ for skill
- [fzf](https://github.com/junegunn/fzf)
- Linux (kernel 5.11+) or macOS (APFS)

## Related

- [gh-q](https://github.com/HikaruEgashira/gh-q) - ghq-like repository management for GitHub CLI
