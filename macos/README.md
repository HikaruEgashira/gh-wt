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

## Distribution

FSKit System Extensions must live inside a signed app bundle in
`/Applications/`, so `gh extension install` alone can't deliver the whole
stack. We split the release into two channels with independent cadences:

| Artefact                     | Channel                                     | What it carries                                  |
| ---------------------------- | ------------------------------------------- | ------------------------------------------------ |
| `gh-wt` + `gh-wt-mount-overlay` | `gh extension install HikaruEgashira/gh-wt` | Shell script + a signed universal CLI binary.    |
| `GhWtOverlay.app` (+ `.fskitmodule`) | `brew install --cask gh-wt-overlay`   | Signed, notarised app bundle with the extension. |

### End-user flow

```bash
gh extension install HikaruEgashira/gh-wt   # shell + helper CLI
brew install --cask gh-wt-overlay           # app + FSKit extension
open /Applications/GhWtOverlay.app          # one-time activation prompt
gh wt doctor                                # verifies all green
```

`gh wt doctor` detects a missing/unactivated extension on Darwin and prints
the exact `brew` / Settings commands the user needs.

### Channel 1 — `gh extension` (CLI side)

Use [`cli/gh-extension-precompile`](https://github.com/cli/gh-extension-precompile)
to ship `gh-wt-mount-overlay` next to the shell script:

1. Add a GitHub Actions workflow that, on tag push (`v*`), runs:
   ```bash
   swift build -c release --arch arm64 --arch x86_64 --product gh-wt-mount-overlay
   codesign --sign "$DEVELOPER_ID" --options runtime --timestamp \
       .build/release/gh-wt-mount-overlay
   ```
2. Upload `gh-wt-mount-overlay-darwin-universal` as a Release asset; let
   the action auto-upload `gh-wt` itself.
3. `gh extension upgrade gh-wt` pulls both on next check.

`gh extension install` already works on Linux (no helper binary needed) —
the precompile step is pure macOS addition.

### Channel 2 — Homebrew Cask (app side)

Homebrew Cask is the right place for signed macOS apps: `brew` verifies
notarisation, installs to `/Applications/`, and handles upgrades.

**Repository layout**

```
homebrew-gh-wt/                # public tap, owned by HikaruEgashira
└── Casks/
    └── gh-wt-overlay.rb
```

**Cask file** (`Casks/gh-wt-overlay.rb`)

```ruby
cask "gh-wt-overlay" do
  version "0.1.0"
  sha256 "<sha256 of the notarised dmg>"

  url "https://github.com/HikaruEgashira/gh-wt/releases/download/v#{version}/GhWtOverlay-#{version}.dmg",
      verified: "github.com/HikaruEgashira/gh-wt/"
  name "gh-wt overlay"
  desc "FSKit System Extension backing `gh wt` on macOS"
  homepage "https://github.com/HikaruEgashira/gh-wt"

  depends_on macos: ">= :tahoe"   # macOS 26+

  app "GhWtOverlay.app"

  postflight do
    system_command "/usr/bin/open", args: ["#{appdir}/GhWtOverlay.app"]
  end

  uninstall delete: "/usr/local/bin/gh-wt-mount-overlay"

  zap trash: [
    "~/Library/Application Support/gh-wt-overlay",
    "~/Library/Logs/gh-wt-overlay",
  ]
end
```

**Listing flow** — once per release:

1. **Build & notarise the DMG** (on a macOS 26 + Xcode 26 runner):
   ```bash
   cd macos
   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" make sign
   hdiutil create -volname "gh-wt overlay" -srcfolder .build/GhWtOverlay.app \
       -ov -format UDZO .build/GhWtOverlay-${VERSION}.dmg
   xcrun notarytool submit .build/GhWtOverlay-${VERSION}.dmg \
       --keychain-profile gh-wt --wait
   xcrun stapler staple .build/GhWtOverlay-${VERSION}.dmg
   ```
2. **Publish the DMG** as a GitHub Release asset under `v${VERSION}`.
3. **Update the Cask**: in `homebrew-gh-wt`, bump `version` and `sha256`
   (computed via `shasum -a 256 GhWtOverlay-${VERSION}.dmg`). Open a PR
   against the tap; CI should run `brew style`, `brew audit --new-cask`
   and `brew install --cask --dry-run`.

**User-facing install**

```bash
brew tap HikaruEgashira/gh-wt              # one-time
brew install --cask gh-wt-overlay
```

**Promotion to homebrew-cask (optional)**

Once the tap has been stable for a while and has users, submit the cask
to the official [`homebrew-cask`](https://github.com/Homebrew/homebrew-cask)
repo. The formula is identical; after acceptance, users can drop the
`brew tap` line:

```bash
brew install --cask gh-wt-overlay
```

Apple Developer Program membership (for Developer ID signing) is a
prerequisite — `homebrew-cask` rejects unsigned/unnotarised apps.

### Enterprise (MDM) distribution

Large orgs can pre-approve the System Extension so users don't have to
toggle anything. Ship the signed `GhWtOverlay.app` via your MDM, and
deploy a configuration profile with a `com.apple.system-extension-policy`
payload:

```xml
<dict>
  <key>PayloadType</key>
  <string>com.apple.system-extension-policy</string>
  <key>AllowedSystemExtensions</key>
  <dict>
    <key>TEAMID</key>
    <array>
      <string>com.github.gh-wt.overlay</string>
    </array>
  </dict>
  <key>AllowedTeamIdentifiers</key>
  <array>
    <string>TEAMID</string>
  </array>
</dict>
```

Paired with the MDM-deployed app, this activates the extension without
prompting the user — the same payload that macFUSE / OrbStack / Rancher
Desktop use. `gh wt doctor` still works as a verification step.

### Self-build (no signing)

For contributors who just want to poke at the code:

```bash
cd macos && make all && sudo make install
```

The unsigned extension will only load on a machine with SIP relaxed
(`csrutil disable`) or one configured for local development with a free
Apple Developer certificate — fine for hacking, not shippable.

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
