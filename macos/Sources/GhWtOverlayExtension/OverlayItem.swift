import Foundation
import FSKit
import OverlayCore
import Darwin

/// One entry in the overlay namespace that FSKit currently has a handle on.
///
/// FSKit identifies items by `FSItem.Identifier` (a 64-bit integer it owns).
/// We hand each unique logical path a stable identifier on first lookup and
/// keep both directions in OverlayVolume's `itemTable`.
final class OverlayItem: FSItem {
    let logicalPath: String
    let identifier: FSItem.Identifier

    init(logicalPath: String, identifier: FSItem.Identifier) {
        self.logicalPath = logicalPath
        self.identifier = identifier
        super.init()
    }

    /// Translate a Darwin stat into the FSItemAttributes FSKit asks for.
    /// Only attributes named in `requested` are populated; the rest are left
    /// at their FSItemAttributes defaults so FSKit knows we didn't fill them.
    static func attributes(from s: Darwin.stat, requested: FSItem.GetAttributesRequest) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        populate(attrs, from: s, wanted: requested.wantedAttributes)
        return attrs
    }

    /// Populate every attribute available from `stat`, regardless of caller
    /// request. Useful when handing back the full snapshot after a setattr.
    static func attributes(from s: Darwin.stat) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        populate(attrs, from: s, wanted: .all)
        return attrs
    }

    private static func populate(_ attrs: FSItem.Attributes, from s: Darwin.stat, wanted: FSItem.Attribute) {
        if wanted.contains(.type) {
            switch s.st_mode & S_IFMT {
            case S_IFREG: attrs.type = .file
            case S_IFDIR: attrs.type = .directory
            case S_IFLNK: attrs.type = .symlink
            default:      attrs.type = .file
            }
        }
        if wanted.contains(.mode)      { attrs.mode  = UInt32(s.st_mode & 0o7777) }
        if wanted.contains(.uid)       { attrs.uid   = s.st_uid }
        if wanted.contains(.gid)       { attrs.gid   = s.st_gid }
        if wanted.contains(.size)      { attrs.size  = UInt64(max(0, s.st_size)) }
        if wanted.contains(.linkCount) { attrs.linkCount = UInt32(s.st_nlink) }
        if wanted.contains(.modifyTime) { attrs.modifyTime = s.st_mtimespec }
        if wanted.contains(.changeTime) { attrs.changeTime = s.st_ctimespec }
        if wanted.contains(.accessTime) { attrs.accessTime = s.st_atimespec }
    }
}

extension FSItem.Attribute {
    static let all: FSItem.Attribute = [
        .type, .mode, .uid, .gid, .size, .linkCount,
        .modifyTime, .changeTime, .accessTime,
    ]
}
