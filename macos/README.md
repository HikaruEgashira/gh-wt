# gh-wt-overlay (macOS / FSKit)

Phase 2 of [gh-wt](../README.md): a FSKit System Extension that provides
OverlayFS-equivalent semantics on macOS so `gh wt add` can do CoW worktrees
without copying repository contents.

## Components

| Path                                     | Role                                                       |
| ---------------------------------------- | ---------------------------------------------------------- |
| `Sources/OverlayCore/`                   | Pure-Swift overlay semantics (lookup, copy-up, whiteout).  |
| `Sources/GhWtOverlayExtension/`          | FSKit `FSUnaryFileSystem` adapter around OverlayCore.      |
| `Sources/GhWtMountOverlay/`              | `gh-wt-mount-overlay` CLI invoked by `lib/overlay.sh`.     |
| `App/`                                   | Host app bundle (`GhWtOverlay.app`) that hosts the extn.   |
| `Tests/OverlayCoreTests/`                | XCTests for OverlayCore (no FSKit, no mount).              |
| `../tests/parity/`                       | Shell tests cross-checking semantics vs Linux OverlayFS.   |

## Build (macOS 26 + Xcode 26)

```bash
cd macos
make all          # builds helper CLI + extension + host app
make test         # runs OverlayCoreTests
```

To produce a signed/notarised distribution:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" make sign
xcrun notarytool submit .build/GhWtOverlay.app --keychain-profile gh-wt --wait
xcrun stapler staple .build/GhWtOverlay.app
```

## Install (end-user, after first build)

```bash
sudo make install
```

This copies:

- `/usr/local/bin/gh-wt-mount-overlay` — the helper CLI
- `/Applications/GhWtOverlay.app` — the host app (just to register the extn)

Then activate the extension once:

1. Open `/Applications/GhWtOverlay.app`. It will request activation.
2. macOS opens **System Settings → General → Login Items & Extensions →
   File System Extensions**. Toggle `gh-wt-overlay` on.
3. Verify with `gh wt doctor`.

## Whiteout encoding

OverlayCore encodes deletions in the upper layer using extended attributes
on plain files (rather than character-device whiteouts, which would need
root):

| Marker      | xattr name                       | Applied to            | Meaning                                   |
| ----------- | -------------------------------- | --------------------- | ----------------------------------------- |
| Whiteout    | `com.github.gh-wt.whiteout`      | empty regular file    | Hides a lower entry of the same name.     |
| Opaque dir  | `com.github.gh-wt.opaque`        | upper directory       | Hides all of lower's contents under it.   |

The upper dir is otherwise a normal POSIX tree; you can `cp -R` it and
re-mount it elsewhere.

## Mount / unmount lifecycle

```
gh wt add <branch>
   └── overlay_mount lower upper work mountpoint        (lib/overlay.sh)
         └── gh-wt-mount-overlay mount …                (Swift CLI)
               └── /usr/sbin/fskit_load --bundle-id …   (macOS 26)
                     └── fskitd loads OverlayFileSystem (FSKit extn)
                           └── extn calls Overlay(lower:upper:)
```

Each successful mount also writes a JSON record under
`~/Library/Application Support/gh-wt-overlay/mounts/`. `gh wt gc` reads
those (via `gh-wt-mount-overlay list-lowers`) to know which references
are still pinned.

## Known gaps

1. **FSKit API drift.** `OverlayVolume.swift` targets the macOS 26 surface
   (e.g. `FSVolume.Operations`, `FSVolume.ReadWriteOperations`). When
   Apple revs the API, adjust the protocol conformances and method
   signatures here; the OverlayCore semantics underneath don't change.
2. **No kernel cache.** FSKit doesn't yet expose `entry_timeout` /
   `attr_timeout`. Large `readdir` loops will be slower than on Linux.
3. **xattr forwarding.** OverlayCore doesn't yet expose user xattrs via
   FSKit's `XattrOperations`. Add this when a real workload needs it.
4. **Single-user activation.** FSKit extensions are activated per user.
   Multi-user hosts need each user to run the activation flow once.
5. **Signing required.** `gh-wt-overlay.app` and its embedded extension
   must be Developer-ID signed and notarised before macOS will load
   them. Local `make all` produces an unsigned bundle that only loads
   with SIP-relaxed dev settings.
