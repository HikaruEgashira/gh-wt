// FileProviderExtension/ReferenceLookup.swift
//
// Maps NSFileProviderItemIdentifier ↔ absolute path inside the
// reference tree, and clones on-demand into the domain's materialised
// storage.
//
// The identifier scheme is a slashy string: ".root" for the root,
// otherwise the path relative to the reference root (without a
// leading slash). This keeps identifiers stable across sessions and
// human-readable in logs; the cost is that rename invalidates
// identifiers, which we accept because reference trees are immutable.

import FileProvider
import Foundation

struct ReferenceLookup {
    let referenceRoot: URL

    func url(for identifier: NSFileProviderItemIdentifier) throws -> URL {
        if identifier == .rootContainer {
            return referenceRoot
        }
        let rel = identifier.rawValue
        // reject absolute paths and traversal
        guard !rel.hasPrefix("/"), !rel.contains("..") else {
            throw NSFileProviderError(.noSuchItem)
        }
        return referenceRoot.appendingPathComponent(rel)
    }

    func identifier(for relPath: String) -> NSFileProviderItemIdentifier {
        if relPath.isEmpty || relPath == "." {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(rawValue: relPath)
    }

    func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        let url = try url(for: identifier)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileType = attrs[.type] as? FileAttributeType ?? .typeUnknown
        let parentIdentifier: NSFileProviderItemIdentifier
        if identifier == .rootContainer {
            parentIdentifier = .rootContainer
        } else {
            let parentRel = (identifier.rawValue as NSString).deletingLastPathComponent
            parentIdentifier = self.identifier(for: parentRel)
        }
        return ReferenceItem(
            identifier: identifier,
            parentIdentifier: parentIdentifier,
            filename: url.lastPathComponent,
            isDirectory: fileType == .typeDirectory,
            size: attrs[.size] as? NSNumber,
            modificationDate: attrs[.modificationDate] as? Date
        )
    }

    /// Materialise a single file into `domainRoot` via clonefile(2) and
    /// hand back the URL for FPE to pass to the kernel.
    func materialise(
        identifier: NSFileProviderItemIdentifier,
        into domainRoot: URL
    ) throws -> (URL, NSFileProviderItem) {
        let src = try url(for: identifier)
        let rel = identifier.rawValue
        let dst = domainRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: dst.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Remove any stale materialisation before clonefile.
        _ = try? FileManager.default.removeItem(at: dst)
        let rc = clonefile(src.path, dst.path, 0)
        if rc != 0 {
            throw NSError(domain: NSPOSIXErrorDomain,
                          code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey:
                            "clonefile failed: \(String(cString: strerror(errno)))"])
        }
        return (dst, try item(for: identifier))
    }
}

/// Minimal NSFileProviderItem. Extend as needed for permissions,
/// versioning, etc.
final class ReferenceItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    private let _isDirectory: Bool
    let documentSize: NSNumber?
    let contentModificationDate: Date?

    init(identifier: NSFileProviderItemIdentifier,
         parentIdentifier: NSFileProviderItemIdentifier,
         filename: String,
         isDirectory: Bool,
         size: NSNumber?,
         modificationDate: Date?) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename
        self._isDirectory = isDirectory
        self.documentSize = size
        self.contentModificationDate = modificationDate
    }

    var contentType: UTType {
        _isDirectory ? .folder : .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        // v0: read-only. Writes are stubbed in Extension.swift.
        [.allowsReading, .allowsContentEnumerating]
    }

    var itemVersion: NSFileProviderItemVersion {
        // Reference trees are immutable per tree-sha, so a constant
        // version is correct. When the caller rebuilds the reference
        // (new tree-sha) a new domain is created.
        NSFileProviderItemVersion(
            contentVersion: "v0".data(using: .utf8)!,
            metadataVersion: "v0".data(using: .utf8)!
        )
    }
}

import UniformTypeIdentifiers

// libc clonefile(2) bridge — declared here because <sys/clonefile.h>
// doesn't currently expose a Swift-importable declaration.
@_silgen_name("clonefile")
private func clonefile(_ src: UnsafePointer<CChar>,
                       _ dst: UnsafePointer<CChar>,
                       _ flags: UInt32) -> Int32
