import Foundation
import Darwin

/// Result of resolving a logical path against the overlay's two layers.
public struct Resolution {
    public enum Source { case upper, lower }
    public let source: Source
    /// Real on-disk path on the underlying filesystem.
    public let realPath: String
    /// Stat of `realPath` at resolution time (best-effort; subject to TOCTOU).
    public let stat: Darwin.stat
}

/// Path lookup against (lower, upper) with whiteout / opaque semantics.
///
/// All paths passed in are *logical*: relative to the overlay root, using "/"
/// as the separator, no leading slash. The empty string "" denotes the root.
public struct OverlayPaths {
    public let lower: String   // absolute path, no trailing slash
    public let upper: String   // absolute path, no trailing slash

    public init(lower: String, upper: String) {
        self.lower = Self.trimTrailingSlash(lower)
        self.upper = Self.trimTrailingSlash(upper)
    }

    public func upperReal(_ logical: String) -> String {
        return logical.isEmpty ? upper : "\(upper)/\(logical)"
    }

    public func lowerReal(_ logical: String) -> String {
        return logical.isEmpty ? lower : "\(lower)/\(logical)"
    }

    /// Resolve a logical path. Returns nil if it doesn't exist (or has been
    /// whited out). Honours opaque markers on intermediate upper directories.
    public func resolve(_ logical: String) -> Resolution? {
        let parts = logical.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if parts.isEmpty {
            if let s = Self.lstat(upper) { return Resolution(source: .upper, realPath: upper, stat: s) }
            if let s = Self.lstat(lower) { return Resolution(source: .lower, realPath: lower, stat: s) }
            return nil
        }

        var opaqueAbove = false
        var built = ""

        for (i, part) in parts.enumerated() {
            built = built.isEmpty ? part : "\(built)/\(part)"
            let upperPath = upperReal(built)
            let lowerPath = lowerReal(built)

            // Whiteout in upper hides this name (and everything below it).
            if Whiteout.isWhiteout(path: upperPath) {
                return nil
            }

            let upperStat = Self.lstat(upperPath)
            let lowerStat = opaqueAbove ? nil : Self.lstat(lowerPath)

            if upperStat == nil && lowerStat == nil {
                return nil
            }

            if i < parts.count - 1 {
                // Intermediate component: must be a directory we can traverse.
                if let us = upperStat, Self.isDir(us) {
                    if Whiteout.isOpaque(path: upperPath) {
                        opaqueAbove = true
                    }
                    continue
                }
                if let ls = lowerStat, Self.isDir(ls) {
                    continue
                }
                return nil
            }

            // Final component: prefer upper.
            if let us = upperStat {
                return Resolution(source: .upper, realPath: upperPath, stat: us)
            }
            if let ls = lowerStat {
                return Resolution(source: .lower, realPath: lowerPath, stat: ls)
            }
            return nil
        }
        return nil
    }

    public static func isDir(_ s: Darwin.stat) -> Bool { (s.st_mode & S_IFMT) == S_IFDIR }
    public static func isReg(_ s: Darwin.stat) -> Bool { (s.st_mode & S_IFMT) == S_IFREG }
    public static func isLnk(_ s: Darwin.stat) -> Bool { (s.st_mode & S_IFMT) == S_IFLNK }

    public static func lstat(_ path: String) -> Darwin.stat? {
        var s = Darwin.stat()
        if Darwin.lstat(path, &s) == 0 { return s }
        return nil
    }

    private static func trimTrailingSlash(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

