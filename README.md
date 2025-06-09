<h2 align="center">
    <p align="center">gh-wt</p>
</h2>

<h3 align="center">
🔹<a  href="https://github.com/HikaruEgashira/gh-wt/issues">Report Bug</a> &nbsp; &nbsp;
🔹<a  href="https://github.com/HikaruEgashira/gh-wt/issues">Request Feature</a>
</h3>

Git worktree management extension for GitHub CLI.

## Installation

```bash
gh extension install HikaruEgashira/gh-wt
```

## Usage

```bash
$ gh wt --help
Usage:
  gh wt list          ... List git worktrees in current repository
  gh wt add <branch> [path] ... Add a new worktree in current repository
  gh wt remove        ... Remove a worktree in current repository
  gh wt *your_command* ... Search via fzf and run *your_command* in the selected worktree
```

### Examples

```bash
# List worktrees in current repository
gh wt list

# Create a new worktree for feature branch
gh wt add feature-branch

# Remove a worktree (interactive selection)
gh wt remove

# Open a worktree in VS Code (interactive selection)
gh wt code
```

## Requirements

- [GitHub CLI](https://cli.github.com/)
- [fzf](https://github.com/junegunn/fzf)
- Must be used within a git repository

## How it works

`gh wt` detects if you're currently in a git repository and operates on that repository's worktrees. If you're not in a git repository, it will exit with an error message.

## Related

- [gh-q](https://github.com/HikaruEgashira/gh-q) - ghq-like repository management for GitHub CLI
