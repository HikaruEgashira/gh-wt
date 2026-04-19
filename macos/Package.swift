// swift-tools-version:5.9
//
// gh-wt-overlay — Swift Package for the macOS overlay implementation.
//
// Products built by `swift build`:
//   - OverlayCore         (library): platform-neutral overlay semantics.
//   - gh-wt-mount-overlay (CLI):     XPC client that talks to the FSKit
//                                    System Extension hosted by the app.
//
// The FSKit System Extension itself is NOT an SPM product because SPM
// cannot emit `.fskitmodule` bundles. Its sources live under
// `Sources/GhWtOverlayExtension` and are compiled by `make extension`
// (see Makefile), which links them into the bundle hosted by GhWtOverlayApp.

import PackageDescription

let package = Package(
    name: "gh-wt-overlay",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OverlayCore", targets: ["OverlayCore"]),
        .executable(name: "gh-wt-mount-overlay", targets: ["GhWtMountOverlay"]),
    ],
    targets: [
        .target(
            name: "OverlayCore",
            path: "Sources/OverlayCore"
        ),
        .executableTarget(
            name: "GhWtMountOverlay",
            dependencies: ["OverlayCore"],
            path: "Sources/GhWtMountOverlay"
        ),
        .testTarget(
            name: "OverlayCoreTests",
            dependencies: ["OverlayCore"],
            path: "Tests/OverlayCoreTests"
        ),
    ]
)
