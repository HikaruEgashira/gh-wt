<h2 align="center">
    <p align="center">gh-wt</p>
</h2>

<h3 align="center">
🔹<a href="https://github.com/HikaruEgashira/gh-wt/issues">Report Bug</a> &nbsp; &nbsp;
🔹<a href="https://github.com/HikaruEgashira/gh-wt/issues">Request Feature</a>
</h3>

Overlay-backed git worktree sessions for GitHub CLI.

## Installation

```bash
gh extension install HikaruEgashira/gh-wt
```

macOS requires an overlay backend. Run `gh wt doctor` for details.

## Usage

```bash
$ gh wt --help
Usage:
  gh wt list                ... List worktrees
  gh wt add <branch> [path] ... Add an overlay-backed worktree
  gh wt remove              ... Remove a worktree (interactive)
  gh wt gc                  ... Delete unreferenced cache entries
  gh wt doctor              ... Check backend setup
  gh wt set-backend <value> ... Persist backend choice (auto, overlayfs, fskit, macfuse, none)
  gh wt *your_command*      ... Search via fzf and run the command in the selected worktree
```

### Examples

```bash
# Create a session for a branch
gh wt add feature-branch

# Remove a session (interactive)
gh wt remove

# Open a worktree in VS Code
gh wt code

# Run a command inside a selected session
gh wt -- claude
```

## Requirements

- [GitHub CLI](https://cli.github.com/)
- [fzf](https://github.com/junegunn/fzf)
- Linux (kernel 5.11+) or macOS

## Related

- [gh-q](https://github.com/HikaruEgashira/gh-q) - ghq-like repository management for GitHub CLI
