// OverlayFileSystem.swift — entry point of the gh-wt-overlay FSKit
// System Extension.
//
// This file is built into the `.fskitmodule` bundle by `make extension`.
// It is NOT compiled by `swift build`, because Swift Package Manager has
// no support for building FSKit modules directly.
//
// FSKit specifics (probeResource / loadResource / unloadResource) follow
// the patterns documented for macOS 26. The adapter here keeps all overlay
// logic in OverlayCore and only translates FSKit identifiers and replies.

import Foundation
import FSKit
import OSLog
import OverlayCore

private let log = Logger(subsystem: "com.github.gh-wt", category: "fs")

@main
final class OverlayFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    // FSKit asks us to "probe" a resource (typically a block device) before
    // loading it. We're a logical overlay, not a block device, so we accept
    // any FSBlockDeviceResource that the helper passed in via XPC and trust
    // the resource's URL (which encodes the lower/upper paths).
    func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void
    ) {
        log.info("probeResource: \(String(describing: resource))")
        let result = FSProbeResult.usable(name: "gh-wt-overlay", containerID: nil)
        reply(result, nil)
    }

    // Load (mount) the volume. Resource carries the lower/upper paths via
    // its bundle identifier or task options (see OverlayResource for the
    // encoding the helper uses).
    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, Error?) -> Void
    ) {
        do {
            let cfg = try OverlayMountConfig.decode(from: resource, options: options)
            log.info("loadResource: lower=\(cfg.lower) upper=\(cfg.upper)")
            let core = try Overlay(lower: cfg.lower, upper: cfg.upper)
            let volume = OverlayVolume(core: core, name: cfg.volumeName)
            reply(volume, nil)
        } catch let err as OverlayError {
            log.error("loadResource failed: \(String(describing: err))")
            reply(nil, NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(err.errno),
                userInfo: [NSLocalizedDescriptionKey: String(describing: err)]
            ))
        } catch {
            log.error("loadResource failed: \(String(describing: error))")
            reply(nil, error)
        }
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        log.info("unloadResource")
        reply(nil)
    }
}
