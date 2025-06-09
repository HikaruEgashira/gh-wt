# gh-wt

Git worktree management extension for GitHub CLI, designed to work with ghq repositories.

## Features

- 🌳 Manage git worktrees in ghq repositories
- 🔍 Interactive worktree selection with fzf
- 📁 Context-aware: works only within ghq repositories
- ⚡ Simple and fast commands

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

# Change directory to a worktree (interactive selection)
gh wt cd
```

## Requirements

- [GitHub CLI](https://cli.github.com/)
- [fzf](https://github.com/junegunn/fzf)
- Must be used within a ghq repository structure (`~/ghq/github.com/owner/repo`)

## How it works

`gh wt` detects if you're currently in a ghq repository (`~/ghq/github.com/owner/repo`) and operates only on that repository's worktrees. If you're not in a ghq repository, it will exit with an error message.

## Related

- [gh-q](https://github.com/HikaruEgashira/gh-q) - ghq-like repository management for GitHub CLI