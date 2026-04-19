// MountClient.swift — drive FSKit mount/unmount via the public
// `mount(8)` / `umount(8)` entry points.
//
// macOS 26 FSKit exposes no programmatic client-side mount API in the
// public SDK (`FSClient` only enumerates modules). The supported flow is:
//
//   1. Extension declares `FSSupportedSchemes = ["gh-wt-overlay"]` in its
//      Info.plist, so FSKit accepts URLs of that scheme as
//      `FSGenericURLResource`.
//   2. Helper builds a `gh-wt-overlay://` URL carrying lower/upper/name
//      (see `OverlayMountURL` in OverlayCore).
//   3. Helper shells out to `mount -t gh-wt-overlay <url> <mountpoint>`.
//      `mount(8)` is FSKit-aware on macOS 26; it proxies through fskitd
//      without requiring root when the extension is user-approved
//      (see FSResource.h: the `mount(8)` tool uses a proxy "which prevents
//      leaking privileged resource access").
//
// No dependence on `/usr/sbin/fskit_load` (Apple-private, moved between
// macOS 26.x releases) and no parallel mount-option encoding.
//
// Unmount is the same as any other volume: `umount(8)`.

import Foundation
import OverlayCore

enum MountClient {
    static let bundleID = "com.github.gh-wt.overlay"
    static let fsType = OverlayMountURL.scheme // "gh-wt-overlay"

    static func mount(lower: String, upper: String, mountpoint: String) throws {
        let absLower = absolute(lower)
        let absUpper = absolute(upper)
        let absMount = absolute(mountpoint)

        try ensureDirectory(absLower, label: "lower")
        try ensureDirectory(absUpper, label: "upper")
        try ensureDirectory(absMount, label: "mountpoint")

        let url = OverlayMountURL.build(.init(
            lower: absLower,
            upper: absUpper,
            volumeName: defaultVolumeName(for: absMount)
        ))

        try Subprocess.run("/sbin/mount", ["-t", fsType, url.absoluteString, absMount])

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
