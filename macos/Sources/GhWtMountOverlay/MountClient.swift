// MountClient.swift — converts mount/unmount intent into FSKit-driven
// system calls.
//
// The flow on macOS 26 is:
//
//   1. Helper resolves lower/upper/mountpoint to absolute paths.
//   2. Helper hands fskitd the bundle ID of our extension plus a
//      configuration dictionary (lower / upper / volume name).
//   3. fskitd loads the extension if needed and asks it to load the
//      "resource"; the extension returns an FSVolume.
//   4. fskitd performs the actual mount(2) at the requested path.
//
// We talk to fskitd via the `fskit_load(8)` / `fskit_unmount(8)` family
// of helpers (shipped with macOS 26). If those are unavailable we fall
// back to `mount(8) -t gh-wt-overlay`, which fskitd registers as a
// filesystem type when the extension is enabled in System Settings.

import Foundation
import OverlayCore

enum MountClient {
    static let bundleID = "com.github.gh-wt.overlay"
    static let fsType   = "gh-wt-overlay"

    static func mount(lower: String, upper: String, mountpoint: String) throws {
        let absLower = absolute(lower)
        let absUpper = absolute(upper)
        let absMount = absolute(mountpoint)

        try ensureDirectory(absLower, label: "lower")
        try ensureDirectory(absUpper, label: "upper")
        try ensureDirectory(absMount, label: "mountpoint")

        // Pack lower/upper/volumeName into a JSON config that fskit_load
        // forwards to the extension as taskInfoDictionary keys.
        let config: [String: String] = [
            OverlayMountConfigKeys.lower: absLower,
            OverlayMountConfigKeys.upper: absUpper,
            OverlayMountConfigKeys.volumeName: defaultVolumeName(for: absMount),
        ]
        let json = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])

        try Subprocess.run(
            "/usr/sbin/fskit_load",
            ["--bundle-id", bundleID, "--mountpoint", absMount, "--config-json", String(data: json, encoding: .utf8)!]
        )

        try MountRegistry.shared.record(
            mountpoint: absMount,
            lower: absLower,
            upper: absUpper
        )
    }

    static func unmount(mountpoint: String) throws {
        let absMount = absolute(mountpoint)
        try Subprocess.run("/sbin/umount", [absMount])
        MountRegistry.shared.forget(mountpoint: absMount)
    }

    private static func absolute(_ path: String) -> String {
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func ensureDirectory(_ path: String, label: String) throws {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if !exists { throw OverlayError(ENOENT, "\(label): \(path)") }
        if !isDir.boolValue { throw OverlayError(ENOTDIR, "\(label): \(path)") }
    }

    private static func defaultVolumeName(for mountpoint: String) -> String {
        let base = (mountpoint as NSString).lastPathComponent
        return base.isEmpty ? "gh-wt-overlay" : base
    }
}

/// Keys must match those in GhWtOverlayExtension/MountConfig.swift. They're
/// duplicated here (rather than imported) because the extension target is
/// not part of the SPM build, so the helper CLI can't depend on it.
enum OverlayMountConfigKeys {
    static let lower      = "gh-wt.lower"
    static let upper      = "gh-wt.upper"
    static let volumeName = "gh-wt.volumeName"
}
