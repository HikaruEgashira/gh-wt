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

        if requested.contains(.type) {
            switch s.st_mode & S_IFMT {
            case S_IFREG: attrs.type = .file
            case S_IFDIR: attrs.type = .directory
            case S_IFLNK: attrs.type = .symlink
            default:      attrs.type = .file
            }
        }
        if requested.contains(.mode)   { attrs.mode  = UInt32(s.st_mode & 0o7777) }
        if requested.contains(.uid)    { attrs.uid   = s.st_uid }
        if requested.contains(.gid)    { attrs.gid   = s.st_gid }
        if requested.contains(.size)   { attrs.size  = UInt64(max(0, s.st_size)) }
        if requested.contains(.linkCount) { attrs.linkCount = UInt32(s.st_nlink) }
        if requested.contains(.modifyTime) {
            attrs.modifyTime = timespecToTimestamp(s.st_mtimespec)
        }
        if requested.contains(.changeTime) {
            attrs.changeTime = timespecToTimestamp(s.st_ctimespec)
        }
        if requested.contains(.accessTime) {
            attrs.accessTime = timespecToTimestamp(s.st_atimespec)
        }
        return attrs
    }

    private static func timespecToTimestamp(_ ts: timespec) -> FSItem.Timestamp {
        return FSItem.Timestamp(seconds: Int64(ts.tv_sec), nanoseconds: UInt32(ts.tv_nsec))
    }
}
