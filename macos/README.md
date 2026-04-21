# gh-wt File Provider Extension (scaffold)

This directory contains an experimental macOS File Provider Extension
(FPE) intended to back `gh wt add` worktrees with a virtual filesystem
so that worktree creation is O(1) regardless of tree size.

**Status**: scaffold only. No signed binary, no CLI integration yet.
See `../docs/file-provider-extension.md` for the design and the scope
boundaries for v0.

## Layout

```
macos/
├── Package.swift                 # SwiftPM manifest (library target)
├── README.md                     # this file
└── FileProviderExtension/
    ├── Extension.swift           # NSFileProviderReplicatedExtension subclass
    ├── ReferenceLookup.swift     # identifier ↔ reference-tree path, clonefile(2)
    ├── Enumerator.swift          # directory listings
    └── Info.plist                # extension metadata for the future .appex
```

## Building (local development)

### Prerequisites

- macOS 13+.
- Xcode 15+ (for `NSFileProviderReplicatedExtension` symbols). The
  command-line tools alone are **not** enough — FPE requires the full
  Xcode IDE to produce an `.appex` bundle.
- An Apple Developer ID code-signing certificate. Self-signed works
  for loading your own-machine-only; distribution needs a real cert.

### SwiftPM smoke build

The SwiftPM manifest compiles just the Swift sources so you can see
type errors without a full Xcode project:

```sh
cd macos
swift build
```

This produces a dylib under `.build/`, **not** a runnable extension.
`swift build` cannot produce `.appex` bundles; that is an Xcode-only
format.

### Producing an .appex (the real build)

Until an Xcode project is checked in, produce one on the fly via
SwiftPM:

```sh
cd macos
swift package generate-xcodeproj
open GhWtFileProvider.xcodeproj
```

Then in Xcode:

1. Add a new **macOS Application** target (the host `.app` that
   embeds the FPE) — call it `GhWtFileProviderHost`.
2. Add a new **File Provider Extension** target — link it against
   the `GhWtFileProvider` library product.
3. Set the File Provider target's *Principal Class* to `Extension`.
4. Copy the `FileProviderExtension/Info.plist` keys into the
   extension target's Info.plist (replacing `$(...)` placeholders
   with your bundle ID).
5. In signing settings: enable
   `com.apple.developer.fileprovider.managed-domain` entitlement.
   Requires a paid Developer ID account; the free personal team has
   the entitlement greyed out.

Build & run the host `.app`. macOS will register the extension at
launch. Verify registration with:

```sh
pluginkit -m -i <your.bundle.id.GhWtFileProvider>
```

### Registering a domain (for manual testing)

With the extension installed, a sample Swift snippet (paste into a
playground) registers a domain pointing at an existing `gh-wt`
reference tree:

```swift
import FileProvider

let domain = NSFileProviderDomain(
    identifier: NSFileProviderDomainIdentifier("gh-wt-demo"),
    displayName: "demo (gh-wt)",
    pathRelativeToDocumentStorage: "demo"
)
domain.userInfo = ["referenceRoot":
    "\(NSHomeDirectory())/.cache/gh-wt/<repo-id>/ref/<tree-sha>"]

try await NSFileProviderManager.add(domain)
```

After this `~/Library/CloudStorage/gh-wt-demo/` should show the
worktree contents. `open -R` on a file triggers `fetchContents` and
measures first-touch latency.

### Removing

```swift
try await NSFileProviderManager.remove(domain)
```

Or, when things are broken, nuclear cleanup:

```sh
sudo rm -rf "~/Library/Application Support/FileProvider"
```

## Wiring into gh-wt (deferred)

The planned CLI path is `gh wt add --virtual <branch> [path]`:

1. Resolve tree SHA and build the reference (existing
   `lib/worktree.sh::build_reference`).
2. Create the File Provider domain with `referenceRoot` pointing at
   the reference.
3. Run `git worktree add --no-checkout` into the domain's
   `userVisibleURL`.
4. Write the `.gh-wt-ref` sidecar + configure worktree stats.

This is **not** implemented in this scaffold — the goal is to prove
the extension model works end-to-end before threading it through the
Bash dispatcher.

## Caveats

- **No CI build.** The scaffold doesn't compile on ubuntu-latest
  runners (no FileProvider.framework there) and `macos-latest` runners
  can't code-sign without provisioning profiles in secrets.
- **SwiftPM is not a shipping path.** Apple's recommended distribution
  is a signed `.pkg` installer or a signed `.app` in the App Store
  — both require a paid Developer ID.
- **First-touch latency is unmeasured.** The design assumes ~ms-class
  first-touch via clonefile; if the FPE RPC overhead dominates, the
  extension may not beat parallel `cp -cRp`. A benchmark is the next
  gate before CLI integration.
