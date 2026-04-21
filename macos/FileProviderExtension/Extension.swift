// FileProviderExtension/Extension.swift
//
// Root class of the gh-wt File Provider Extension. Implements
// NSFileProviderReplicatedExtension so that the domain appears fully
// populated to userspace but files are materialised lazily via
// clonefile(2) from a shared reference tree.
//
// This file is the entry point; see ReferenceLookup.swift for the
// mapping from virtual paths to on-disk reference blobs, and
// Enumerator.swift for directory listings.
//
// Not wired into gh-wt yet. See docs/file-provider-extension.md.

import FileProvider
import Foundation

final class Extension: NSObject, NSFileProviderReplicatedExtension {

    /// Populated from NSFileProviderManager via the domain's userInfo.
    /// This is the absolute path of the reference tree this domain is
    /// backed by — e.g. `~/.cache/gh-wt/<repo-id>/ref/<tree-sha>/`.
    private let referenceRoot: URL

    /// The domain's per-session upper directory. Writes land here;
    /// reads fall through to the reference.
    private let domainRoot: URL

    private let lookup: ReferenceLookup

    required init(domain: NSFileProviderDomain) {
        let userInfo = domain.userInfo ?? [:]
        guard let refPathString = userInfo["referenceRoot"] as? String else {
            fatalError("gh-wt FP: domain missing referenceRoot userInfo key")
        }
        self.referenceRoot = URL(fileURLWithPath: refPathString, isDirectory: true)
        // FPE extensions write materialised files into their sandbox;
        // the manager exposes the per-domain URL via `userVisibleURL`
        // but internal scratch must live inside the extension container.
        // We stage per-domain under NSTemporaryDirectory for v0 — the
        // real build will swap in the manager's per-domain URL once a
        // proper host app + entitlement flow exists.
        self.domainRoot = URL(fileURLWithPath: NSTemporaryDirectory(),
                              isDirectory: true)
            .appendingPathComponent("gh-wt-fp-\(domain.identifier.rawValue)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: domainRoot,
                                                 withIntermediateDirectories: true)
        self.lookup = ReferenceLookup(referenceRoot: referenceRoot)
        super.init()
    }

    func invalidate() {
        // Nothing to tear down — ReferenceLookup is stateless.
    }

    // MARK: - item resolution

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            let item = try lookup.item(for: identifier)
            completionHandler(item, nil)
            progress.completedUnitCount = 1
        } catch {
            completionHandler(nil, error)
        }
        return progress
    }

    // MARK: - content fetch (lazy materialisation)

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            let (url, item) = try lookup.materialise(identifier: itemIdentifier,
                                                     into: domainRoot)
            completionHandler(url, item, nil)
            progress.completedUnitCount = 1
        } catch {
            completionHandler(nil, nil, error)
        }
        return progress
    }

    // MARK: - enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        return Enumerator(lookup: lookup, container: containerItemIdentifier)
    }

    // MARK: - writes (stub)
    //
    // Writes into the worktree happen through the domain's upper
    // directory. The FPE daemon reports createItem/modifyItem/deleteItem
    // callbacks; we record the change and let APFS keep file content.
    // v0: return .featureNotSupported so create/delete fail cleanly.
    // A later revision will persist mutations in domainRoot.

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, readOnlyError())
        return Progress(totalUnitCount: 0)
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, readOnlyError())
        return Progress(totalUnitCount: 0)
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(readOnlyError())
        return Progress(totalUnitCount: 0)
    }
}

/// EROFS — "Read-only filesystem". FPE surfaces POSIX errors as a
/// well-known fallback when it doesn't recognise the NSError domain,
/// so this gives callers a meaningful errno at the system call level.
private func readOnlyError() -> NSError {
    return NSError(domain: NSPOSIXErrorDomain,
                   code: 30,  // EROFS
                   userInfo: [NSLocalizedDescriptionKey:
                              "gh-wt File Provider is read-only in v0"])
}
