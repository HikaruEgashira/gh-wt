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
  gh wt -- <command>  ... Search via fzf and run <command> in the selected worktree
  gh wt <command>     ... Search via fzf and run <command> with selected worktree as argument
```

### Examples

```bash
# List worktrees in current repository
gh wt list

# Create a new worktree for feature branch
gh wt add feature-branch

# Remove a worktree (interactive selection)
gh wt remove

# Open a worktree in VS Code (path as argument)
gh wt code

# Run commands in the selected worktree directory
gh wt -- claude
gh wt -- git status
gh wt -- npm test
```

## Command Execution Modes

There are two ways to execute commands with selected worktrees:

1. **`gh wt <command>`** - Passes the worktree path as an argument to the command
   - Example: `gh wt code` → executes `code /path/to/selected/worktree`
   - Useful for editors and tools that accept directory paths as arguments

2. **`gh wt -- <command>`** - Changes to the worktree directory and executes the command
   - Example: `gh wt -- git status` → changes to worktree directory then runs `git status`
   - Useful for commands that need to run within the project directory

## Requirements

- [GitHub CLI](https://cli.github.com/)
- [fzf](https://github.com/junegunn/fzf)
- Must be used within a git repository

## How it works

`gh wt` detects if you're currently in a git repository and operates on that repository's worktrees. If you're not in a git repository, it will exit with an error message.

## Dependency Sharing

When creating a worktree, dependencies are automatically linked to the parent repository:

| Language | Shared Directory |
|----------|-----------------|
| Node.js | node_modules |
| Python | .venv |
| Rust | target |

## Integration with other gh extensions

Works well with:
- [`gh-q`](https://github.com/HikaruEgashira/gh-q): Quick repository navigation
- [`gh-ws`](https://github.com/HikaruEgashira/gh-ws): VSCode workspace management with worktrees

```bash
# Example workflow
gh q                    # Select repository
gh wt add feature/new   # Create new worktree
gh ws init              # Create/update workspace
```
