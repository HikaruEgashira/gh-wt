import Foundation
import Darwin

/// Top-level overlay façade. The FSKit extension and the test harness both
/// drive this directly; FSKit's volume operations are thin adapters.
///
/// All paths passed in are *logical*: relative to the overlay root, "/"
/// separated, no leading slash. The empty string is the root.
public final class Overlay {
    public let paths: OverlayPaths

    public init(lower: String, upper: String) throws {
        self.paths = OverlayPaths(lower: lower, upper: upper)
        try Self.requireDirectory(paths.lower, label: "lower")
        try Self.requireDirectory(paths.upper, label: "upper")
    }

    private static func requireDirectory(_ path: String, label: String) throws {
        guard let s = OverlayPaths.lstat(path), OverlayPaths.isDir(s) else {
            throw OverlayError(ENOTDIR, "\(label): \(path)")
        }
    }

    // MARK: - Read-side operations

    /// Resolve a logical path (or nil if absent / whited-out).
    public func resolve(_ logical: String) -> Resolution? {
        return paths.resolve(logical)
    }

    /// Stat the logical path. Throws ENOENT if absent.
    public func stat(_ logical: String) throws -> Darwin.stat {
        guard let r = paths.resolve(logical) else { throw OverlayError.notFound }
        return r.stat
    }

    /// List entries of a directory at `logical`. Returns merged names with
    /// upper precedence; whiteouts hide lower names; opaque dirs hide all
    /// lower contents.
    public func readdir(_ logical: String) throws -> [DirEntry] {
        guard let r = paths.resolve(logical) else { throw OverlayError.notFound }
        guard OverlayPaths.isDir(r.stat) else { throw OverlayError.notADirectory }

        var hidden = Set<String>()        // names hidden by whiteout
        var entries: [String: DirEntry] = [:]

        let upperPath = paths.upperReal(logical)
        let upperOpaque = OverlayPaths.lstat(upperPath).map { OverlayPaths.isDir($0) } == true
            && Whiteout.isOpaque(path: upperPath)

        if let s = OverlayPaths.lstat(upperPath), OverlayPaths.isDir(s) {
            for name in Self.scanDirectory(upperPath) {
                let real = "\(upperPath)/\(name)"
                if Whiteout.isWhiteout(path: real) {
                    hidden.insert(name)
                    continue
                }
                if let st = OverlayPaths.lstat(real) {
                    entries[name] = DirEntry(name: name, source: .upper, stat: st)
                }
            }
        }

        if !upperOpaque {
            let lowerPath = paths.lowerReal(logical)
            if let s = OverlayPaths.lstat(lowerPath), OverlayPaths.isDir(s) {
                for name in Self.scanDirectory(lowerPath) {
                    if hidden.contains(name) || entries[name] != nil { continue }
                    let real = "\(lowerPath)/\(name)"
                    if let st = OverlayPaths.lstat(real) {
                        entries[name] = DirEntry(name: name, source: .lower, stat: st)
                    }
                }
            }
        }

        return entries.values.sorted { $0.name < $1.name }
    }

    public struct DirEntry {
        public let name: String
        public let source: Resolution.Source
        public let stat: Darwin.stat
    }

    /// Read up to `length` bytes from `logical` starting at `offset`.
    public func read(_ logical: String, offset: off_t, length: Int) throws -> Data {
        guard let r = paths.resolve(logical) else { throw OverlayError.notFound }
        guard OverlayPaths.isReg(r.stat) else { throw OverlayError.isADirectory }

        let fd = open(r.realPath, O_RDONLY)
        if fd < 0 { throw OverlayError(errno, "read open") }
        defer { close(fd) }

        if lseek(fd, offset, SEEK_SET) < 0 { throw OverlayError(errno, "read lseek") }

        var buf = Data(count: length)
        let n = buf.withUnsafeMutableBytes { ptr -> ssize_t in
            return Darwin.read(fd, ptr.baseAddress, length)
        }
        if n < 0 { throw OverlayError(errno, "read") }
        buf.count = n
        return buf
    }

    public func readlink(_ logical: String) throws -> String {
        guard let r = paths.resolve(logical) else { throw OverlayError.notFound }
        guard OverlayPaths.isLnk(r.stat) else { throw OverlayError.invalid }
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        let n = Darwin.readlink(r.realPath, &buf, buf.count - 1)
        if n < 0 { throw OverlayError(errno, "readlink") }
        return String(cString: buf)
    }

    // MARK: - Write-side operations

    /// Write `data` at `offset` in `logical`. If the file lives only in lower,
    /// it is copied up first. Creates the file if it doesn't exist.
    public func write(_ logical: String, offset: off_t, data: Data) throws -> Int {
        try ensureUpperFile(logical)
        let upperPath = paths.upperReal(logical)
        let fd = open(upperPath, O_WRONLY)
        if fd < 0 { throw OverlayError(errno, "write open") }
        defer { close(fd) }

        if lseek(fd, offset, SEEK_SET) < 0 { throw OverlayError(errno, "write lseek") }
        let n = data.withUnsafeBytes { ptr -> ssize_t in
            return Darwin.write(fd, ptr.baseAddress, data.count)
        }
        if n < 0 { throw OverlayError(errno, "write") }
        return n
    }

    /// Truncate `logical` to `length`. Copies up if needed.
    public func truncate(_ logical: String, length: off_t) throws {
        try ensureUpperFile(logical)
        if Darwin.truncate(paths.upperReal(logical), length) != 0 {
            throw OverlayError(errno, "truncate")
        }
    }

    /// Create a regular file at `logical` (must not already exist).
    public func createFile(_ logical: String, mode: mode_t) throws {
        if paths.resolve(logical) != nil { throw OverlayError.alreadyExists }
        try ensureParentInUpper(logical)
        let real = paths.upperReal(logical)
        try Whiteout.clearWhiteout(path: real)
        let fd = open(real, O_CREAT | O_EXCL | O_WRONLY, mode)
        if fd < 0 { throw OverlayError(errno, "createFile") }
        close(fd)
    }

    /// Create a directory at `logical`. If the resolved entry was a directory
    /// in lower (i.e. already visible), this is EEXIST. If lower had a dir
    /// and there was a whiteout in upper hiding it, we create the upper dir
    /// and mark it opaque so lower's children don't reappear.
    public func mkdir(_ logical: String, mode: mode_t) throws {
        let real = paths.upperReal(logical)

        let lowerHadDir: Bool
        let lowerHadEntry: Bool
        let lowerStat = OverlayPaths.lstat(paths.lowerReal(logical))
        lowerHadEntry = lowerStat != nil
        lowerHadDir = lowerStat.map { OverlayPaths.isDir($0) } == true

        let upperWhiteout = Whiteout.isWhiteout(path: real)

        if !upperWhiteout, paths.resolve(logical) != nil {
            throw OverlayError.alreadyExists
        }

        try ensureParentInUpper(logical)
        try Whiteout.clearWhiteout(path: real)

        if Darwin.mkdir(real, mode) != 0 {
            throw OverlayError(errno, "mkdir")
        }

        if lowerHadEntry {
            // The mkdir replaces a previously-whited-out lower entry. If the
            // lower entry was a directory, mark our new upper dir opaque so
            // lower's children stay hidden. If it was a file, no opaque
            // needed (the whiteout already hid it; we just removed the
            // whiteout sentinel for our new dir).
            if lowerHadDir {
                try Whiteout.markOpaque(path: real)
            }
        }
    }

    public func symlink(_ target: String, at logical: String) throws {
        if paths.resolve(logical) != nil { throw OverlayError.alreadyExists }
        try ensureParentInUpper(logical)
        let real = paths.upperReal(logical)
        try Whiteout.clearWhiteout(path: real)
        if Darwin.symlink(target, real) != 0 {
            throw OverlayError(errno, "symlink")
        }
    }

    /// Remove `logical`. If it exists in lower, leave a whiteout in upper.
    public func remove(_ logical: String) throws {
        guard let r = paths.resolve(logical) else { throw OverlayError.notFound }

        let upperPath = paths.upperReal(logical)
        let lowerExists = OverlayPaths.lstat(paths.lowerReal(logical)) != nil

        if r.source == .upper {
            if OverlayPaths.isDir(r.stat) {
                if !readdirRaw(upperPath).isEmpty { throw OverlayError.notEmpty }
                if Darwin.rmdir(upperPath) != 0 { throw OverlayError(errno, "rmdir upper") }
            } else {
                if Darwin.unlink(upperPath) != 0 { throw OverlayError(errno, "unlink upper") }
            }
        } else {
            // Removing a lower-only entry: no upper file to delete.
            if OverlayPaths.isDir(r.stat) {
                let entries = try readdir(logical)
                if !entries.isEmpty { throw OverlayError.notEmpty }
            }
        }

        if lowerExists {
            try ensureParentInUpper(logical)
            try Whiteout.createWhiteout(path: upperPath)
        }
    }

    /// Rename src -> dst. v0 implementation: copy-up source if needed, mv in
    /// upper, then if src was visible in lower leave a whiteout at the old
    /// name in upper.
    public func rename(_ src: String, to dst: String) throws {
        guard let srcRes = paths.resolve(src) else { throw OverlayError.notFound }

        // Reject overwriting a directory with a file or vice-versa, matching
        // POSIX semantics. (FSKit may call us with a more specific check
        // already, but be defensive.)
        if let dstRes = paths.resolve(dst) {
            if OverlayPaths.isDir(srcRes.stat) != OverlayPaths.isDir(dstRes.stat) {
                throw OverlayError.invalid
            }
            if OverlayPaths.isDir(dstRes.stat) {
                let dstEntries = try readdir(dst)
                if !dstEntries.isEmpty { throw OverlayError.notEmpty }
            }
        }

        // Copy up source if it's lower-only.
        if srcRes.source == .lower {
            try copyUp(src)
        }

        try ensureParentInUpper(dst)

        let srcReal = paths.upperReal(src)
        let dstReal = paths.upperReal(dst)
        try Whiteout.clearWhiteout(path: dstReal)
        if Darwin.rename(srcReal, dstReal) != 0 {
            throw OverlayError(errno, "rename")
        }

        // If src existed in lower, leave a whiteout at the old name so the
        // lower entry doesn't reappear.
        if OverlayPaths.lstat(paths.lowerReal(src)) != nil {
            try Whiteout.createWhiteout(path: srcReal)
        }
    }

    public func chmod(_ logical: String, mode: mode_t) throws {
        try ensureUpperFile(logical)
        if Darwin.chmod(paths.upperReal(logical), mode) != 0 {
            throw OverlayError(errno, "chmod")
        }
    }

    // MARK: - Internal helpers

    /// Ensure the parent directory of `logical` exists in upper. Walks lower
    /// and copies missing intermediates as plain directories (not opaque —
    /// they're meant to expose lower siblings).
    private func ensureParentInUpper(_ logical: String) throws {
        let parts = logical.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return }
        var built = ""
        for component in parts.dropLast() {
            built = built.isEmpty ? component : "\(built)/\(component)"
            let upperPath = paths.upperReal(built)
            if let s = OverlayPaths.lstat(upperPath) {
                if !OverlayPaths.isDir(s) { throw OverlayError.notADirectory }
                continue
            }
            // Mirror lower's mode if available, else 0o755.
            let lowerStat = OverlayPaths.lstat(paths.lowerReal(built))
            let mode: mode_t = lowerStat.map { $0.st_mode & 0o7777 } ?? 0o755
            if Darwin.mkdir(upperPath, mode) != 0 && errno != EEXIST {
                throw OverlayError(errno, "mkdir parent")
            }
        }
    }

    /// Ensure the file at `logical` is materialised in upper. If it lives in
    /// lower, copy it up. If it doesn't exist anywhere, create an empty file.
    private func ensureUpperFile(_ logical: String) throws {
        let upperPath = paths.upperReal(logical)
        if let s = OverlayPaths.lstat(upperPath), OverlayPaths.isReg(s) { return }
        try ensureParentInUpper(logical)
        if let s = OverlayPaths.lstat(upperPath) {
            // Wrong type in upper (whiteout file, dir, …). Caller bug.
            _ = s
            throw OverlayError.invalid
        }
        if let _ = paths.resolve(logical) {
            try copyUp(logical)
        } else {
            let fd = open(upperPath, O_CREAT | O_WRONLY, 0o644)
            if fd < 0 { throw OverlayError(errno, "ensureUpperFile create") }
            close(fd)
        }
    }

    /// Copy a file (or symlink) from lower to upper preserving mode + mtime.
    /// Caller must ensure the parent exists in upper and there's no upper
    /// entry already.
    public func copyUp(_ logical: String) throws {
        guard let r = paths.resolve(logical), r.source == .lower else { return }
        let dst = paths.upperReal(logical)

        if OverlayPaths.isDir(r.stat) {
            if Darwin.mkdir(dst, r.stat.st_mode & 0o7777) != 0 && errno != EEXIST {
                throw OverlayError(errno, "copyUp mkdir")
            }
            return
        }

        if OverlayPaths.isLnk(r.stat) {
            var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
            let n = Darwin.readlink(r.realPath, &buf, buf.count - 1)
            if n < 0 { throw OverlayError(errno, "copyUp readlink") }
            let target = String(cString: buf)
            if Darwin.symlink(target, dst) != 0 { throw OverlayError(errno, "copyUp symlink") }
            return
        }

        // Regular file.
        let inFd = open(r.realPath, O_RDONLY)
        if inFd < 0 { throw OverlayError(errno, "copyUp open lower") }
        defer { close(inFd) }
        let outFd = open(dst, O_CREAT | O_EXCL | O_WRONLY, r.stat.st_mode & 0o7777)
        if outFd < 0 { throw OverlayError(errno, "copyUp open upper") }
        defer { close(outFd) }

        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(inFd, $0.baseAddress, $0.count) }
            if n == 0 { break }
            if n < 0 { throw OverlayError(errno, "copyUp read") }
            var written = 0
            while written < n {
                let w = buf.withUnsafeBufferPointer {
                    Darwin.write(outFd, $0.baseAddress!.advanced(by: written), n - written)
                }
                if w <= 0 { throw OverlayError(errno, "copyUp write") }
                written += w
            }
        }
    }

    /// Plain readdir of a real on-disk path, filtering "." and "..".
    private func readdirRaw(_ realPath: String) -> [String] {
        return Self.scanDirectory(realPath).filter { !Whiteout.isWhiteout(path: "\(realPath)/\($0)") }
    }

    static func scanDirectory(_ path: String) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var out: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            out.append(name)
        }
        return out
    }
}
