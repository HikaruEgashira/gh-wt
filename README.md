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

Backend: kernel OverlayFS (always).

**macOS** — pick one backend.

*FSKit (default on macOS 26+, sandboxed, no kext):*

```bash
gh extension install HikaruEgashira/gh-wt   # shell + helper CLI
brew install --cask gh-wt-overlay           # FSKit System Extension
open /Applications/GhWtOverlay.app          # one-time activation
gh wt doctor                                # verify
```

*macFUSE (works on pre-macOS 26, needs a third-party kext):*

```bash
gh extension install HikaruEgashira/gh-wt
brew install --cask macfuse                 # reboot + approve in System Settings
brew install gh-wt-mount-overlay-fuse       # macFUSE helper CLI
GH_WT_BACKEND=macfuse gh wt doctor
```

`gh wt doctor` tells you exactly what's missing (extension not installed,
not activated, wrong macOS version, macFUSE not approved, …) and prints
the commands to fix it.

### Selecting a backend

`gh-wt` auto-detects the best available backend. Override with
`GH_WT_BACKEND` (one-shot) or persist the choice with
`gh wt set-backend <value>`, which writes
`${XDG_CONFIG_HOME:-~/.config}/gh-wt/config`:

| value       | platform | backend                       |
| ----------- | -------- | ----------------------------- |
| `auto`      | any      | pick the best available (default) |
| `overlayfs` | Linux    | kernel OverlayFS              |
| `fskit`     | macOS 26+| FSKit System Extension        |
| `macfuse`   | macOS    | macFUSE (libfuse, userspace)  |
| `none`      | any      | plain `git worktree add` (no overlay, no shared cache) |

Precedence: `GH_WT_BACKEND` env var > XDG config > `auto`. The `none`
backend is the portable fallback — use it when you don't need the shared
reference layer or can't install a kernel helper.

Not supported: Windows, kernels without OverlayFS, bare repos, submodule
repos (deferred to v1).

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
