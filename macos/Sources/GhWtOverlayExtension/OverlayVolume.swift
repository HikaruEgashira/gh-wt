import Foundation
import FSKit
import OverlayCore
import OSLog
import Darwin

private let log = Logger(subsystem: "com.github.gh-wt", category: "volume")

/// One mounted overlay. Translates FSKit volume operations to OverlayCore
/// calls. The actual semantic decisions (whiteout, copy-up, opaque) all live
/// in OverlayCore so the parity test suite can exercise them headless.
final class OverlayVolume: FSVolume,
                           FSVolume.Operations,
                           FSVolume.PathConfOperations,
                           FSVolume.OpenCloseOperations,
                           FSVolume.ReadWriteOperations {

    let core: Overlay
    let volumeName: String

    private let queue = DispatchQueue(label: "gh-wt.overlay.volume")
    private var nextID: UInt64 = 1024  // First user-allocated ID; reserved IDs sit below.
    private var pathToID: [String: FSItem.Identifier] = [:]
    private var idToItem: [FSItem.Identifier: OverlayItem] = [:]
    private let rootItem: OverlayItem

    init(core: Overlay, name: String) {
        self.core = core
        self.volumeName = name
        self.rootItem = OverlayItem(logicalPath: "", identifier: .rootDirectory)
        super.init(volumeID: FSVolume.Identifier(uuid: UUID()),
                   volumeName: FSFileName(string: name))
        idToItem[.rootDirectory] = rootItem
        pathToID[""] = .rootDirectory
    }

    // MARK: - FSVolume.PathConfOperations

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { Int(NAME_MAX) }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 64 * 1024 }
    var maximumFileSize: UInt64 { UInt64.max }

    // MARK: - FSVolume.Operations capabilities + statfs

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsHardLinks = false
        caps.supportsSymbolicLinks = true
        caps.supportsHiddenFiles = true
        caps.supportsPersistentObjectIDs = false
        caps.doesNotSupportVolumeSizes = true
        caps.caseFormat = .sensitive
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let s = FSStatFSResult(fileSystemTypeName: "gh-wt-overlay")
        s.blockSize = 4096
        s.ioSize = 64 * 1024
        return s
    }

    // MARK: - activate / deactivate / mount / unmount / sync

    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, Error?) -> Void) {
        log.info("activate lower=\(self.core.paths.lower) upper=\(self.core.paths.upper)")
        reply(rootItem, nil)
    }

    func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping (Error?) -> Void) {
        log.info("deactivate")
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) {
        log.info("mount")
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        log.info("unmount")
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    // MARK: - getAttributes / setAttributes

    func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let it = item as? OverlayItem else { reply(nil, posix(EINVAL)); return }
        do {
            let s = try core.stat(it.logicalPath)
            reply(OverlayItem.attributes(from: s, requested: desiredAttributes), nil)
        } catch let err as OverlayError {
            reply(nil, posix(err.errno))
        } catch {
            reply(nil, error)
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let it = item as? OverlayItem else { reply(nil, posix(EINVAL)); return }
        do {
            var consumed: FSItem.Attribute = []
            if newAttributes.isValid(.mode) {
                try core.chmod(it.logicalPath, mode: mode_t(newAttributes.mode))
                consumed.insert(.mode)
            }
            if newAttributes.isValid(.size) {
                try core.truncate(it.logicalPath, length: off_t(newAttributes.size))
                consumed.insert(.size)
            }
            newAttributes.consumedAttributes = consumed
            let s = try core.stat(it.logicalPath)
            reply(OverlayItem.attributes(from: s), nil)
        } catch let err as OverlayError {
            reply(nil, posix(err.errno))
        } catch {
            reply(nil, error)
        }
    }

    // MARK: - lookupItem / reclaim / symlink read

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let parent = directory as? OverlayItem,
              let nm = name.string else {
            reply(nil, nil, posix(EINVAL)); return
        }
        let logical = join(parent.logicalPath, nm)
        guard core.resolve(logical) != nil else {
            reply(nil, nil, posix(ENOENT)); return
        }
        let item = ensureItem(forLogical: logical)
        reply(item, name, nil)
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping (Error?) -> Void) {
        if let it = item as? OverlayItem {
            forgetItemByID(it.identifier, logical: it.logicalPath)
        }
        reply(nil)
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        guard let it = item as? OverlayItem else { reply(nil, posix(EINVAL)); return }
        do {
            let target = try core.readlink(it.logicalPath)
            reply(FSFileName(string: target), nil)
        } catch let err as OverlayError {
            reply(nil, posix(err.errno))
        } catch {
            reply(nil, error)
        }
    }

    // MARK: - create / removeItem / rename

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let parent = directory as? OverlayItem,
              let nm = name.string else {
            reply(nil, nil, posix(EINVAL)); return
        }
        let logical = join(parent.logicalPath, nm)
        let mode: mode_t = newAttributes.isValid(.mode) ? mode_t(newAttributes.mode) : 0o644
        do {
            switch type {
            case .file:      try core.createFile(logical, mode: mode)
            case .directory: try core.mkdir(logical, mode: mode)
            default:
                reply(nil, nil, posix(EOPNOTSUPP)); return
            }
            let item = ensureItem(forLogical: logical)
            reply(item, name, nil)
        } catch let err as OverlayError {
            reply(nil, nil, posix(err.errno))
        } catch {
            reply(nil, nil, error)
        }
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let parent = directory as? OverlayItem,
              let nm = name.string,
              let target = contents.string else {
            reply(nil, nil, posix(EINVAL)); return
        }
        let logical = join(parent.logicalPath, nm)
        do {
            try core.symlink(target, at: logical)
            let item = ensureItem(forLogical: logical)
            reply(item, name, nil)
        } catch let err as OverlayError {
            reply(nil, nil, posix(err.errno))
        } catch {
            reply(nil, nil, error)
        }
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSFileName?, Error?) -> Void
    ) {
        // Hard links are not supported by the overlay (whiteout semantics make
        // it ambiguous which layer holds the canonical inode).
        reply(nil, posix(ENOTSUP))
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        guard let parent = directory as? OverlayItem,
              let nm = name.string else {
            reply(posix(EINVAL)); return
        }
        let logical = join(parent.logicalPath, nm)
        do {
            try core.remove(logical)
            forgetItem(logical)
            reply(nil)
        } catch let err as OverlayError {
            reply(posix(err.errno))
        } catch {
            reply(error)
        }
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler reply: @escaping (FSFileName?, Error?) -> Void
    ) {
        guard let src = sourceDirectory as? OverlayItem,
              let dst = destinationDirectory as? OverlayItem,
              let sn = sourceName.string,
              let dn = destinationName.string else {
            reply(nil, posix(EINVAL)); return
        }
        let srcLogical = join(src.logicalPath, sn)
        let dstLogical = join(dst.logicalPath, dn)
        do {
            try core.rename(srcLogical, to: dstLogical)
            renameItemInTable(srcLogical: srcLogical, dstLogical: dstLogical)
            reply(destinationName, nil)
        } catch let err as OverlayError {
            reply(nil, posix(err.errno))
        } catch {
            reply(nil, error)
        }
    }

    // MARK: - enumerateDirectory

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes attrRequest: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping (FSDirectoryVerifier, Error?) -> Void
    ) {
        guard let dir = directory as? OverlayItem else { reply(verifier, posix(EINVAL)); return }
        do {
            let entries = try core.readdir(dir.logicalPath)
            var index: UInt64 = 0
            // When attributes weren't requested, FSKit expects "." and ".." entries.
            if attrRequest == nil {
                index += 1
                if index > cookie.rawValue {
                    if !packer.packEntry(name: FSFileName(string: "."),
                                         itemType: .directory,
                                         itemID: dir.identifier,
                                         nextCookie: FSDirectoryCookie(rawValue: index),
                                         attributes: nil) {
                        reply(verifier, nil); return
                    }
                }
                index += 1
                if index > cookie.rawValue {
                    let parentID = parentIdentifier(of: dir)
                    if !packer.packEntry(name: FSFileName(string: ".."),
                                         itemType: .directory,
                                         itemID: parentID,
                                         nextCookie: FSDirectoryCookie(rawValue: index),
                                         attributes: nil) {
                        reply(verifier, nil); return
                    }
                }
            }
            for entry in entries {
                index += 1
                if index <= cookie.rawValue { continue }
                let logical = join(dir.logicalPath, entry.name)
                let id = ensureItem(forLogical: logical).identifier
                let type: FSItem.ItemType = OverlayPaths.isDir(entry.stat) ? .directory
                                          : OverlayPaths.isLnk(entry.stat) ? .symlink
                                          : .file
                let attrs = attrRequest.map { OverlayItem.attributes(from: entry.stat, requested: $0) }
                if !packer.packEntry(name: FSFileName(string: entry.name),
                                     itemType: type,
                                     itemID: id,
                                     nextCookie: FSDirectoryCookie(rawValue: index),
                                     attributes: attrs) {
                    break
                }
            }
            reply(verifier, nil)
        } catch let err as OverlayError {
            reply(verifier, posix(err.errno))
        } catch {
            reply(verifier, error)
        }
    }

    // MARK: - read / write

    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping (Int, Error?) -> Void
    ) {
        guard let it = item as? OverlayItem else { reply(0, posix(EINVAL)); return }
        do {
            let data = try core.read(it.logicalPath, offset: offset, length: length)
            let n = buffer.withUnsafeMutableBytes { dest -> Int in
                let copyCount = min(dest.count, data.count)
                if copyCount > 0, let base = dest.baseAddress {
                    data.copyBytes(to: base.assumingMemoryBound(to: UInt8.self), count: copyCount)
                }
                return copyCount
            }
            reply(n, nil)
        } catch let err as OverlayError {
            reply(0, posix(err.errno))
        } catch {
            reply(0, error)
        }
    }

    func write(
        contents data: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler reply: @escaping (Int, Error?) -> Void
    ) {
        guard let it = item as? OverlayItem else { reply(0, posix(EINVAL)); return }
        do {
            let n = try core.write(it.logicalPath, offset: offset, data: data)
            reply(n, nil)
        } catch let err as OverlayError {
            reply(0, posix(err.errno))
        } catch {
            reply(0, error)
        }
    }

    // MARK: - OpenCloseOperations

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    // MARK: - Identifier table

    private func ensureItem(forLogical logical: String) -> OverlayItem {
        return queue.sync {
            if let id = pathToID[logical], let it = idToItem[id] { return it }
            nextID += 1
            let id = FSItem.Identifier(rawValue: nextID)!
            let item = OverlayItem(logicalPath: logical, identifier: id)
            pathToID[logical] = id
            idToItem[id] = item
            return item
        }
    }

    private func forgetItem(_ logical: String) {
        queue.sync {
            if let id = pathToID.removeValue(forKey: logical) {
                idToItem.removeValue(forKey: id)
            }
        }
    }

    private func forgetItemByID(_ id: FSItem.Identifier, logical: String) {
        queue.sync {
            idToItem.removeValue(forKey: id)
            if pathToID[logical] == id { pathToID.removeValue(forKey: logical) }
        }
    }

    private func renameItemInTable(srcLogical: String, dstLogical: String) {
        queue.sync {
            if let id = pathToID.removeValue(forKey: srcLogical) {
                pathToID[dstLogical] = id
                let renamed = OverlayItem(logicalPath: dstLogical, identifier: id)
                idToItem[id] = renamed
            }
        }
    }

    private func join(_ parent: String, _ name: String) -> String {
        if parent.isEmpty { return name }
        return "\(parent)/\(name)"
    }

    private func parentIdentifier(of dir: OverlayItem) -> FSItem.Identifier {
        let path = dir.logicalPath
        if path.isEmpty { return dir.identifier }
        guard let slash = path.lastIndex(of: "/") else {
            return rootItem.identifier
        }
        let parentPath = String(path[..<slash])
        return ensureItem(forLogical: parentPath).identifier
    }

    private func posix(_ e: Int32) -> Error {
        return NSError(domain: NSPOSIXErrorDomain, code: Int(e))
    }
}
