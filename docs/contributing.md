# Contributing

## Repo layout

```
gh-wt                          # the gh extension entry point (bash)
lib/                           # shell modules: env, cache, overlay, worktree
docs/                          # this directory
```

`docs/architecture.md` describes *what* these parts do. This page
covers *how to build and test* them.

## Running from a working tree

```bash
bash -n gh-wt lib/*.sh            # syntax check
PATH="$PWD:$PATH" gh wt add test-branch
```

## Commit conventions

Conventional commit prefixes (see `git log` for examples):

- `feat(scope): …` for new features
- `fix(scope): …` for bug fixes
- `docs(scope): …` for documentation
- `refactor(scope): …` for internal cleanup
- `chore(scope): …` for anything else

Keep commits focused; prefer many small commits over a single mega-PR.
