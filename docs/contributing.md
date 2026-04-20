# Contributing

## Repo layout

```
gh-wt                          # the gh extension entry point (bash)
lib/                           # shell modules: env, cache, overlay, worktree
tests/parity/                  # OverlayFS semantics parity tests (Linux)
docs/                          # this directory
```

`docs/architecture.md` describes *what* these parts do. This page
covers *how to build and test* them.

## Running from a working tree

```bash
bash -n gh-wt lib/*.sh            # syntax check
PATH="$PWD:$PATH" gh wt doctor
PATH="$PWD:$PATH" gh wt add test-branch
```

## Parity tests (Linux)

```bash
sudo ./tests/parity/run.sh
```

Mounts identical fixtures with OverlayFS and asserts the documented
semantics across cases like lower visibility, copy-up on write,
whiteouts, readdir merge, rename of lower-only entries, rmdir-then-mkdir
opacity, partial offset writes, and chmod copy-up.

Add new cases by dropping a file into `tests/parity/cases/NN_name.sh`
with `fixture` and `verify` functions — see existing cases for the
shape.

## macOS smoke

APFS clonefile has no parity harness yet — verify by hand:

```bash
gh wt doctor                 # reports APFS clonefile ok
gh wt add <branch>           # worktree appears, `git status` is clean
gh wt gc                     # removes unreferenced cache entries
```

## Commit conventions

Conventional commit prefixes (see `git log` for examples):

- `feat(scope): …` for new features
- `fix(scope): …` for bug fixes
- `docs(scope): …` for documentation
- `refactor(scope): …` for internal cleanup
- `chore(scope): …` for anything else

Keep commits focused; prefer many small commits over a single mega-PR.
