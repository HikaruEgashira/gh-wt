<div align="center">
    <h2 align="center">gh-wt</h2>
    <small align="center">Overlay-backed worktree sessions for git</small>
</div>

<h3 align="center">
🔹<a href="https://github.com/HikaruEgashira/gh-wt/issues">Report Bug</a> &nbsp; &nbsp;
🔹<a href="https://github.com/HikaruEgashira/gh-wt/issues">Request Feature</a>
</h3>

`gh wt` gives you a `git worktree` that's a copy-on-write overlay instead
of a physical clone. Worktrees start in tens of milliseconds and N of them
cost `1 × repo_size + Σ per-session diffs` on disk.

## Install

**Linux** (kernel 5.11+, root or passwordless `sudo`)

```bash
gh extension install HikaruEgashira/gh-wt
```

**macOS** (26+, Apple silicon or Intel)

```bash
gh extension install HikaruEgashira/gh-wt   # shell + helper CLI
brew install --cask gh-wt-overlay           # FSKit System Extension
open /Applications/GhWtOverlay.app          # one-time activation
gh wt doctor                                # verify
```

`gh wt doctor` tells you exactly what's missing (extension not installed,
not activated, wrong macOS version, …) and prints the commands to fix it.

Not supported: Windows, older macOS, kernels without OverlayFS, bare
repos, submodule repos (deferred to v1).

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

# Run a command inside a selected session
gh wt -- claude
gh wt -- git status

# Pass a selected session's path as the last argument
gh wt code
```

## Tips

- Writes in a session stay in that session — `node_modules`, `target/`
  and friends are **not** shared. For heavy build caches, route them
  to a scratch dir with env vars like `CARGO_TARGET_DIR`, `GOCACHE`,
  `PIP_CACHE_DIR`.
- The cache lives at `~/.cache/gh-wt/`. Override with `GH_WT_CACHE=/path`.
- Combine with [`gh-q`](https://github.com/HikaruEgashira/gh-q) for
  quick repository switching:
  ```bash
  gh q                    # pick a repo
  gh wt add feature/new   # start a session in it
  gh wt -- codex          # drop into the session
  ```

## Further reading

- [`docs/architecture.md`](docs/architecture.md) — how the overlay, cache
  and `git worktree` integration actually work.
- [`docs/distribution.md`](docs/distribution.md) — how releases are cut
  (gh-extension-precompile, Homebrew Cask, enterprise MDM).
- [`docs/contributing.md`](docs/contributing.md) — building from source,
  running the parity test suite, macOS-specific notes.
