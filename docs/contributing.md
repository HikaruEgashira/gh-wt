# Contributing

## Repo layout

```
gh-wt                          # the gh extension entry point (bash)
lib/                           # shell modules: env, cache, overlay, worktree
macos/                         # Swift Package for the macOS overlay backend
  Sources/
    OverlayCore/               # pure-Swift overlay semantics
    GhWtOverlayExtension/      # FSKit adapter (not an SPM product)
    GhWtMountOverlay/          # helper CLI invoked by lib/overlay.sh
  App/                         # host app bundle for the FSKit extension
  Tests/OverlayCoreTests/      # headless XCTests for OverlayCore
  Makefile                     # build / sign / install targets
tests/parity/                  # Linux vs macOS overlay semantics parity tests
docs/                          # this directory
```

`docs/architecture.md` describes *what* these parts do. This page
covers *how to build and test* them.

## Linux

```bash
bash -n gh-wt lib/*.sh                         # syntax check
sudo ./tests/parity/run.sh                     # parity suite against OverlayFS
```

Running `gh wt` locally from a working tree:

```bash
PATH="$PWD:$PATH" gh wt doctor
PATH="$PWD:$PATH" gh wt add test-branch
```

## macOS (26 + Xcode 26)

```bash
cd macos
make all           # helper CLI + .fskitmodule + host app
make test          # OverlayCoreTests (no FSKit, no mount)
```

Signed / notarised build:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" make sign
xcrun notarytool submit .build/GhWtOverlay.app --keychain-profile gh-wt --wait
xcrun stapler staple .build/GhWtOverlay.app
```

Local install (unsigned) for hacking:

```bash
sudo make install
```

The unsigned extension only loads with SIP relaxed
(`csrutil disable`) or on a machine configured for local development
with a free Apple Developer certificate. Fine for iterating, not
shippable — see `docs/distribution.md` for the real release flow.

### End-to-end check

```bash
open /Applications/GhWtOverlay.app   # activates the extension
gh wt doctor                          # reports all green
gh wt add <branch>                    # <500 ms on a warm cache
gh wt remove                          # unmounts cleanly
```

## Parity tests

`tests/parity/run.sh` mounts identical fixtures with the platform-native
overlay (OverlayFS on Linux, FSKit on macOS) and asserts identical
observable behaviour across nine cases: lower visibility, copy-up on
write, whiteouts, readdir merge, rename of lower-only entries,
rmdir-then-mkdir opacity, partial offset writes, chmod copy-up.

Add new cases by dropping a file into `tests/parity/cases/NN_name.sh`
with `fixture` and `verify` functions — see existing cases for the
shape.

## OverlayCore unit tests (macOS)

`macos/Tests/OverlayCoreTests/OverlayTests.swift` exercises
OverlayCore directly — no FSKit, no mount, no root. Run with
`make test` or `swift test` from `macos/`.

These are faster than the parity suite and the right place to
regression-test semantic bugs (whiteout, copy-up, opaque) before they
hit a mount.

## Commit conventions

The repo uses conventional commit prefixes (see `git log` for
examples):

- `feat(scope): …` for new features
- `fix(scope): …` for bug fixes
- `docs(scope): …` for documentation
- `refactor(scope): …` for internal cleanup
- `chore(scope): …` for anything else

Keep commits focused; prefer many small commits over a single mega-PR.
