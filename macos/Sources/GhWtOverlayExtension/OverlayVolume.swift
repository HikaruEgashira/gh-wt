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
    let name: String

    private let queue = DispatchQueue(label: "gh-wt.overlay.volume")
    private var nextID: UInt64 = 2  // 1 reserved for root
    private var pathToID: [String: FSItem.Identifier] = ["": .rootDirectory]
    private var idToItem: [FSItem.Identifier: OverlayItem] = [:]

    init(core: Overlay, name: String) {
        self.core = core
        self.name = name
        super.init(volumeID: FSVolume.Identifier(uuid: UUID()), volumeName: name)
        let root = OverlayItem(logicalPath: "", identifier: .rootDirectory)
        idToItem[.rootDirectory] = root
    }

    // MARK: - FSVolume.PathConfOperations

    var maximumLinkCount: Int32 { Int32.max }
    var maximumNameLength: Int32 { Int32(NAME_MAX) }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int32 { Int32(64 * 1024) }
    var maximumFileSize: UInt64 { UInt64.max }

    // MARK: - mount / unmount

    func mount(options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) {
        log.info("mount lower=\(self.core.paths.lower) upper=\(self.core.paths.upper)")
        reply(nil)
    }

    func unmount() async {
        log.info("unmount")
    }

    // MARK: - lookup / enumerate

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let parent = directory as? OverlayItem else {
            reply(nil, nil, posix(EINVAL)); return
        }
        let logical = join(parent.logicalPath, name.string)
        guard core.resolve(logical) != nil else {
            reply(nil, nil, posix(ENOENT)); return
        }
        let item = ensureItem(forLogical: logical)
        reply(item, name, nil)
    }

    func attributes(
        forItem item: FSItem,
        requestedAttributes request: FSItem.GetAttributesRequest,
        replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let it = item as? OverlayItem else { reply(nil, posix(EINVAL)); return }
        do {
            let s = try core.stat(it.logicalPath)
            reply(OverlayItem.attributes(from: s, requested: request), nil)
        } catch let err as OverlayError {
            reply(nil, posix(err.errno))
        } catch {
            reply(nil, error)
        }
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes attrRequest: FSItem.GetAttributesRequest?,
        packer pack: (FSFileName, FSItem.ItemType, UInt64, FSDirectoryCookie, FSItem.Attributes?) -> Bool,
        replyHandler reply: @escaping (FSDirectoryVerifier, Error?) -> Void
    ) {
        guard let dir = directory as? OverlayItem else { reply(verifier, posix(EINVAL)); return }
        do {
            let entries = try core.readdir(dir.logicalPath)
            var index: UInt64 = 0
            for entry in entries {
                index += 1
                if index <= cookie.rawValue { continue }
                let logical = join(dir.logicalPath, entry.name)
                let id = ensureItem(forLogical: logical).identifier
                let type: FSItem.ItemType = OverlayPaths.isDir(entry.stat) ? .directory
                                          : OverlayPaths.isLnk(entry.stat) ? .symlink
                                          : .file
                let attrs = attrRequest.map { OverlayItem.attributes(from: entry.stat, requested: $0) }
                if !pack(FSFileName(string: entry.name), type, id.rawValue, FSDirectoryCookie(rawValue: index), attrs) {
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

    // MARK: - create / mkdir / symlink

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let parent = directory as? OverlayItem else {
            reply(nil, nil, posix(EINVAL)); return
        }
        let logical = join(parent.logicalPath, name.string)
        let mode = mode_t(attributes.mode ?? 0o644)
        do {
            switch type {
            case .file:      try core.createFile(logical, mode: mode)
            case .directory: try core.mkdir(logical, mode: mode)
            case .symlink:
                guard let target = attributes.linkTarget?.string else {
                    reply(nil, nil, posix(EINVAL)); return
                }
                try core.symlink(target, at: logical)
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

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        guard let parent = directory as? OverlayItem else { reply(posix(EINVAL)); return }
        let logical = join(parent.logicalPath, name.string)
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
        to destinationDirectory: FSItem,
        named destinationName: FSFileName,
        overItem: FSItem?,
        replyHandler reply: @escaping (FSFileName?, Error?) -> Void
    ) {
        guard let src = sourceDirectory as? OverlayItem,
              let dst = destinationDirectory as? OverlayItem else {
            reply(nil, posix(EINVAL)); return
        }
        let srcLogical = join(src.logicalPath, sourceName.string)
        let dstLogical = join(dst.logicalPath, destinationName.string)
        do {
            try core.rename(srcLogical, to: dstLogical)
            renameItem(srcLogical: srcLogical, dstLogical: dstLogical)
            reply(destinationName, nil)
        } catch let err as OverlayError {
            reply(nil, posix(err.errno))
        } catch {
            reply(nil, error)
        }
    }

    // MARK: - read / write

    func read(
        from item: FSItem,
        offset: UInt64,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping (Int, Error?) -> Void
    ) {
        guard let it = item as? OverlayItem else { reply(0, posix(EINVAL)); return }
        do {
            let data = try core.read(it.logicalPath, offset: off_t(offset), length: length)
            data.withUnsafeBytes { src in
                _ = buffer.replaceContents(in: 0..<data.count, with: src.bindMemory(to: UInt8.self).baseAddress!)
            }
            reply(data.count, nil)
        } catch let err as OverlayError {
            reply(0, posix(err.errno))
        } catch {
            reply(0, error)
        }
    }

    func write(
        contents data: Data,
        to item: FSItem,
        offset: UInt64,
        replyHandler reply: @escaping (Int, Error?) -> Void
    ) {
        guard let it = item as? OverlayItem else { reply(0, posix(EINVAL)); return }
        do {
            let n = try core.write(it.logicalPath, offset: off_t(offset), data: data)
            reply(n, nil)
        } catch let err as OverlayError {
            reply(0, posix(err.errno))
        } catch {
            reply(0, error)
        }
    }

    func setAttributes(
        request: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let it = item as? OverlayItem else { reply(nil, posix(EINVAL)); return }
        do {
            if let mode = request.mode { try core.chmod(it.logicalPath, mode: mode_t(mode)) }
            if let size = request.size { try core.truncate(it.logicalPath, length: off_t(size)) }
            let s = try core.stat(it.logicalPath)
            let attrs = OverlayItem.attributes(from: s, requested: .all)
            reply(attrs, nil)
        } catch let err as OverlayError {
            reply(nil, posix(err.errno))
        } catch {
            reply(nil, error)
        }
    }

    // MARK: - OpenCloseOperations

    func openItem(_ item: FSItem, modes: FSItem.AccessMode, replyHandler reply: @escaping (Error?) -> Void) {
        // Stateless open — OverlayCore opens the underlying file per read/write.
        // FSKit's caching means this is only called once per (process, fd).
        reply(nil)
    }

    func closeItem(_ item: FSItem, modes: FSItem.AccessMode, replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    // MARK: - Identifier table

    private func ensureItem(forLogical logical: String) -> OverlayItem {
        return queue.sync {
            if let id = pathToID[logical], let it = idToItem[id] { return it }
            let id = FSItem.Identifier(rawValue: nextID); nextID += 1
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

    private func renameItem(srcLogical: String, dstLogical: String) {
        queue.sync {
            if let id = pathToID.removeValue(forKey: srcLogical) {
                pathToID[dstLogical] = id
                if let it = idToItem[id] {
                    let renamed = OverlayItem(logicalPath: dstLogical, identifier: id)
                    idToItem[id] = renamed
                    _ = it
                }
            }
        }
    }

    private func join(_ parent: String, _ name: String) -> String {
        if parent.isEmpty { return name }
        return "\(parent)/\(name)"
    }

    private func posix(_ e: Int32) -> Error {
        return NSError(domain: NSPOSIXErrorDomain, code: Int(e))
    }
}
