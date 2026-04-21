// swift-tools-version:6.0
// gh-wt File Provider Extension — scaffolding only.
//
// This package compiles the Swift sources into a library that a host
// `.app` bundle can embed as an extension. It is NOT a ready-to-run
// extension: File Provider extensions require a signed `.appex` bundle
// inside a host `.app`, which this plain SwiftPM manifest cannot
// produce on its own (Xcode + a Developer ID cert are the sanctioned
// path). See ../docs/file-provider-extension.md §6 for the build story.
import PackageDescription

let package = Package(
    name: "GhWtFileProvider",
    platforms: [
        // macOS 15+ because we use NSFileProviderDomain.userInfo to
        // pass the reference-tree path at domain creation. Pre-15
        // would need an out-of-band channel (plist in shared
        // container, XPC) which is overkill for the scaffold.
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "GhWtFileProvider",
            type: .dynamic,
            targets: ["GhWtFileProvider"]
        ),
    ],
    targets: [
        .target(
            name: "GhWtFileProvider",
            path: "FileProviderExtension",
            exclude: ["Info.plist"]
        ),
    ]
)
