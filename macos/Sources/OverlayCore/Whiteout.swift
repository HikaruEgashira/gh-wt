import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Whiteout / opaque encoding on the upper layer.
///
/// We use extended attributes rather than character-device whiteouts so that
/// (a) the upper layer is a perfectly normal POSIX directory tree and (b) we
/// don't depend on creating special device nodes (which need root on macOS).
///
/// - `whiteoutAttr` on a regular empty file means "the lower entry with this
///   name is hidden". The file itself is invisible to the user — the overlay
///   reports ENOENT for it.
/// - `opaqueAttr` on a directory in the upper means "ignore lower's contents
///   under this directory; only show what's in upper". Used after `mkdir`
///   over a path where lower had a directory.
public enum Whiteout {
    public static let whiteoutAttr = "com.github.gh-wt.whiteout"
    public static let opaqueAttr   = "com.github.gh-wt.opaque"
    public static let markerValue: [UInt8] = [0x31] // "1"

    public static func isWhiteout(path: String) -> Bool {
        return hasXattr(path: path, name: whiteoutAttr)
    }

    public static func isOpaque(path: String) -> Bool {
        return hasXattr(path: path, name: opaqueAttr)
    }

    public static func markOpaque(path: String) throws {
        try setXattr(path: path, name: opaqueAttr, value: markerValue)
    }

    /// Create or overwrite a whiteout marker at `path`. Replaces any existing
    /// regular file at that path with an empty file carrying the xattr.
    public static func createWhiteout(path: String, mode: mode_t = 0o600) throws {
        // Remove any existing entry at `path` so we start from a clean file.
        if access(path, F_OK) == 0 {
            if unlink(path) != 0 && errno != ENOENT {
                throw OverlayError(errno, "whiteout: unlink existing")
            }
        }
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, mode)
        if fd < 0 { throw OverlayError(errno, "whiteout: open") }
        close(fd)
        try setXattr(path: path, name: whiteoutAttr, value: markerValue)
    }

    /// Remove a whiteout marker (clears the xattr and unlinks the empty file).
    public static func clearWhiteout(path: String) throws {
        if isWhiteout(path: path) {
            if unlink(path) != 0 && errno != ENOENT {
                throw OverlayError(errno, "whiteout: clear")
            }
        }
    }

    // MARK: - xattr shim (macOS / Linux differ in signature)

    private static func hasXattr(path: String, name: String) -> Bool {
        var buf: UInt8 = 0
        #if canImport(Darwin)
        let r = getxattr(path, name, &buf, 1, 0, XATTR_NOFOLLOW)
        #else
        let r = lgetxattr(path, name, &buf, 1)
        #endif
        if r >= 0 { return true }
        // ENOATTR (macOS) / ENODATA (Linux) means "no such xattr"; anything
        // else (ENOENT, EACCES, …) we treat as "not a whiteout" and let the
        // caller hit the underlying error on the next syscall.
        return false
    }

    private static func setXattr(path: String, name: String, value: [UInt8]) throws {
        let r = value.withUnsafeBufferPointer { buf -> Int32 in
            #if canImport(Darwin)
            return Int32(setxattr(path, name, buf.baseAddress, buf.count, 0, XATTR_NOFOLLOW))
            #else
            return Int32(lsetxattr(path, name, buf.baseAddress, buf.count, 0))
            #endif
        }
        if r != 0 { throw OverlayError(errno, "setxattr \(name)") }
    }
}
