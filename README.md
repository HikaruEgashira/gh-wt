<p align="center">
    <h2 align="center">gh-wt</h2>
    <small align="center">Explenable, worktree management</small>
</p>

<h3 align="center">
🔹<a  href="https://github.com/HikaruEgashira/gh-wt/issues">Report Bug</a> &nbsp; &nbsp;
🔹<a  href="https://github.com/HikaruEgashira/gh-wt/issues">Request Feature</a>
</h3>

#### Example

```bash
gh extension install HikaruEgashira/gh-wt

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

#### Help

```bash
$ gh wt --help
Usage:
  gh wt list          ... List git worktrees in current repository
  gh wt add <branch> [path] ... Add a new worktree in current repository
  gh wt remove        ... Remove a worktree in current repository
  gh wt -- <command>  ... Search via fzf and run <command> in the selected worktree
  gh wt <command>     ... Search via fzf and run <command> with selected worktree as argument
```


### Feature1: fzf Native Integration

#### Path Argument Mode
Passes the worktree path as an argument to the command
```bash
gh wt code # Opens VS Code with the selected directory
```

#### Directory Change Mode
Changes to the worktree directory and executes the command
```bash
gh wt -- claude # Run Claude Code in the selected directory
gh wt --        # Opens a shell in the selected directory
```

### Feature2: Dependency Caching

When creating a worktree, dependencies are automatically linked to the parent repository

| Source | Shared Directory |
|--------|-----------------|
| Node.js | node_modules |
| Python | .venv |
| Rust | target |
| Go | vendor |
| Ruby | vendor/bundle |
| Swift | .build |
| Zig | zig-cache, .zig-cache |
| Deno | deno_dir |
| .gitignore | Any directory listed in .gitignore |

## Acknowledgements

- [`gh-q`](https://github.com/HikaruEgashira/gh-q): Quick repository navigation

```bash
gh q                    # Select repository
gh q --                 # Change directory
gh wt add feature/new   # Create new worktree
gh wt -- codex          # Open worktree in Codex
```
