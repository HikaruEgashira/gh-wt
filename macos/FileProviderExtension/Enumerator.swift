// FileProviderExtension/Enumerator.swift
//
// Streams the children of a virtual directory back to FPE. The
// reference tree is on-disk and immutable, so enumeration is a plain
// directory read — no sync token, no pagination.

import FileProvider
import Foundation

final class Enumerator: NSObject, NSFileProviderEnumerator {
    private let lookup: ReferenceLookup
    private let container: NSFileProviderItemIdentifier

    init(lookup: ReferenceLookup, container: NSFileProviderItemIdentifier) {
        self.lookup = lookup
        self.container = container
        super.init()
    }

    func invalidate() {
        // stateless
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        do {
            let dirURL = try lookup.url(for: container)
            let children = try FileManager.default.contentsOfDirectory(
                atPath: dirURL.path
            )
            let prefix = (container == .rootContainer)
                ? ""
                : container.rawValue + "/"
            let items: [NSFileProviderItem] = try children.map { name in
                let rel = prefix + name
                return try lookup.item(for: NSFileProviderItemIdentifier(rawValue: rel))
            }
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        // Reference trees are immutable per tree-sha. No changes to
        // report; FPE will keep the last-seen anchor.
        observer.finishEnumeratingChanges(
            upTo: anchor,
            moreComing: false
        )
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        // Constant anchor — the tree never changes.
        completionHandler(NSFileProviderSyncAnchor("v0".data(using: .utf8)!))
    }
}
