# Distribution

FSKit System Extensions must live inside a signed app bundle in
`/Applications/`, so `gh extension install` alone can't deliver the whole
stack. Releases split across two channels with independent cadences:

| Artefact                              | Channel                                     | Carries                                          |
| ------------------------------------- | ------------------------------------------- | ------------------------------------------------ |
| `gh-wt` + `gh-wt-mount-overlay`       | `gh extension install HikaruEgashira/gh-wt` | Shell script + signed universal CLI binary.      |
| `GhWtOverlay.app` (+ `.fskitmodule`)  | `brew install --cask gh-wt-overlay`         | Signed, notarised app bundle with the extension. |

## End-user flow

```bash
gh extension install HikaruEgashira/gh-wt   # shell + helper CLI
brew install --cask gh-wt-overlay           # app + FSKit extension
open /Applications/GhWtOverlay.app          # one-time activation
gh wt doctor                                # verify
```

`gh wt doctor` detects a missing/unactivated extension on Darwin and
prints the exact `brew` / Settings commands to fix it.

## Channel 1 — `gh extension` (CLI side)

Use [`cli/gh-extension-precompile`](https://github.com/cli/gh-extension-precompile)
to ship `gh-wt-mount-overlay` alongside the shell script:

1. Tag a release (`v*`). A GitHub Actions workflow builds the CLI on a
   macOS 26 runner:
   ```bash
   swift build -c release --arch arm64 --arch x86_64 \
       --product gh-wt-mount-overlay
   codesign --sign "$DEVELOPER_ID" --options runtime --timestamp \
       .build/release/gh-wt-mount-overlay
   ```
2. Upload `gh-wt-mount-overlay-darwin-universal` as a Release asset.
   The action auto-uploads the shell script too.
3. `gh extension upgrade gh-wt` pulls both on next check.

Linux users install via `gh extension install` without the helper
binary — the precompile step is pure macOS addition.

## Channel 2 — Homebrew Cask (app side)

Homebrew Cask is the right place for signed macOS apps: `brew` verifies
notarisation, installs to `/Applications/`, and handles upgrades.

### Repository layout

```
homebrew-gh-wt/                # public tap, owned by HikaruEgashira
└── Casks/
    └── gh-wt-overlay.rb
```

### Cask file — `Casks/gh-wt-overlay.rb`

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

### Listing flow — once per release

1. **Build and notarise the DMG** on a macOS 26 + Xcode 26 runner:
   ```bash
   cd macos
   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" make sign
   hdiutil create -volname "gh-wt overlay" \
       -srcfolder .build/GhWtOverlay.app \
       -ov -format UDZO \
       .build/GhWtOverlay-${VERSION}.dmg
   xcrun notarytool submit .build/GhWtOverlay-${VERSION}.dmg \
       --keychain-profile gh-wt --wait
   xcrun stapler staple .build/GhWtOverlay-${VERSION}.dmg
   ```
2. **Publish the DMG** as a GitHub Release asset under `v${VERSION}`.
3. **Update the Cask**: in `homebrew-gh-wt`, bump `version` and
   `sha256` (computed via `shasum -a 256 GhWtOverlay-${VERSION}.dmg`).
   Open a PR against the tap; CI should run `brew style`,
   `brew audit --new-cask`, and `brew install --cask --dry-run`.

### User-facing install

```bash
brew tap HikaruEgashira/gh-wt              # one-time
brew install --cask gh-wt-overlay
```

### Promotion to homebrew-cask (optional)

Once the tap has been stable and has users, submit the cask to the
official [`homebrew-cask`](https://github.com/Homebrew/homebrew-cask)
repo. The formula is identical; after acceptance users drop the
`brew tap` line:

```bash
brew install --cask gh-wt-overlay
```

Apple Developer Program membership (for Developer ID signing) is a
prerequisite — `homebrew-cask` rejects unsigned/unnotarised apps.

## Enterprise (MDM)

Large orgs can pre-approve the System Extension so users don't have to
toggle anything. Ship the signed `GhWtOverlay.app` via your MDM and
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
prompting the user — the same payload macFUSE / OrbStack / Rancher
Desktop use. `gh wt doctor` still works as a verification step.
