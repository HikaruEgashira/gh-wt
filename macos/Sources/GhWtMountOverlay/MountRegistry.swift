// MountRegistry.swift — per-user record of live overlay mounts.
//
// macOS doesn't have an equivalent of /proc/mounts that lets us recover the
// lower/upper paths of a live overlay (only the mountpoint). We persist a
// small index under ~/Library/Application Support/gh-wt-overlay/mounts/ so
// `gh wt gc` (which calls `list-lowers`) can decide which references are
// still pinned by a live mount.
//
// Each record is a JSON file named after the SHA-1 of the mountpoint path.
// On unmount we delete the record. If the helper crashes between mount(2)
// and writing the record, gc will see the reference as eligible for
// deletion — `mount(8) -t gh-wt-overlay` is the source of truth for which
// mounts are live, so we cross-check before deleting.

import Foundation
import OverlayCore
import CryptoKit

struct MountRecord: Codable {
    let mountpoint: String
    let lower: String
    let upper: String
    let pid: Int32
    let createdAt: Date
}

final class MountRegistry {
    static let shared = MountRegistry()

    private let dir: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.dir = support.appendingPathComponent("gh-wt-overlay/mounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func record(mountpoint: String, lower: String, upper: String) throws {
        let r = MountRecord(
            mountpoint: mountpoint,
            lower: lower,
            upper: upper,
            pid: getpid(),
            createdAt: Date()
        )
        let data = try JSONEncoder().encode(r)
        try data.write(to: file(for: mountpoint), options: .atomic)
    }

    func forget(mountpoint: String) {
        try? FileManager.default.removeItem(at: file(for: mountpoint))
    }

    /// Read every record and return the lowerdir path of each mount whose
    /// mountpoint is still live according to `mount(8)`.
    func liveLowers() -> [String] {
        let liveMountpoints = Set(currentMountpoints())
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var lowers: [String] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let rec = try? JSONDecoder().decode(MountRecord.self, from: data) else { continue }
            if liveMountpoints.contains(rec.mountpoint) {
                lowers.append(rec.lower)
            } else {
                // Stale record; clean it up opportunistically.
                try? FileManager.default.removeItem(at: url)
            }
        }
        return lowers.sorted().reduce(into: []) { acc, s in
            if acc.last != s { acc.append(s) }
        }
    }

    private func currentMountpoints() -> [String] {
        // /sbin/mount output: "FROM on /Mountpoint (...)"
        let p = Process()
        p.launchPath = "/sbin/mount"
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        var out: [String] = []
        for line in text.split(separator: "\n") {
            // " on /Volumes/foo (..."
            guard let onRange = line.range(of: " on ") else { continue }
            let after = line[onRange.upperBound...]
            guard let parenRange = after.range(of: " (") else { continue }
            out.append(String(after[..<parenRange.lowerBound]))
        }
        return out
    }

    private func file(for mountpoint: String) -> URL {
        let hash = SHA256.hash(data: Data(mountpoint.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(hash).json")
    }
}
