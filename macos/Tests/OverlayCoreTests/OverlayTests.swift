import XCTest
import Foundation
@testable import OverlayCore

/// Headless tests for OverlayCore. These don't go through FSKit at all —
/// they operate on the underlying filesystem directly, so they run on
/// macOS only (because Whiteout uses macOS's xattr signature) but don't
/// need any extension, mount, or root.
final class OverlayTests: XCTestCase {

    var lower: String!
    var upper: String!

    override func setUp() {
        super.setUp()
        lower = mkTemp("lower")
        upper = mkTemp("upper")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: lower)
        try? FileManager.default.removeItem(atPath: upper)
        super.tearDown()
    }

    func testLowerVisibleThroughResolve() throws {
        try writeFile(at: "\(lower!)/hello.txt", "hi")
        let o = try Overlay(lower: lower, upper: upper)
        let r = try XCTUnwrap(o.resolve("hello.txt"))
        XCTAssertEqual(r.source, .lower)
    }

    func testWriteCreatesUpper() throws {
        try writeFile(at: "\(lower!)/file", "lower")
        let o = try Overlay(lower: lower, upper: upper)
        _ = try o.write("file", offset: 0, data: Data("upper".utf8))
        let body = try o.read("file", offset: 0, length: 16)
        XCTAssertEqual(String(data: body, encoding: .utf8), "upper")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(upper!)/file"))
        // Lower must be untouched.
        XCTAssertEqual(try String(contentsOfFile: "\(lower!)/file"), "lower")
    }

    func testRemoveLowerLeavesWhiteout() throws {
        try writeFile(at: "\(lower!)/gone", "x")
        let o = try Overlay(lower: lower, upper: upper)
        try o.remove("gone")
        XCTAssertNil(o.resolve("gone"))
        XCTAssertTrue(Whiteout.isWhiteout(path: "\(upper!)/gone"))
    }

    func testReaddirMergesWithUpperPrecedence() throws {
        try writeFile(at: "\(lower!)/a", "L")
        try writeFile(at: "\(lower!)/b", "L")
        let o = try Overlay(lower: lower, upper: upper)
        try o.createFile("c", mode: 0o644)
        _ = try o.write("b", offset: 0, data: Data("U".utf8))
        let names = try o.readdir("").map { $0.name }
        XCTAssertEqual(names, ["a", "b", "c"])
    }

    func testRmdirRecreateMakesOpaque() throws {
        try FileManager.default.createDirectory(atPath: "\(lower!)/d", withIntermediateDirectories: true)
        try writeFile(at: "\(lower!)/d/leaf", "L")
        let o = try Overlay(lower: lower, upper: upper)
        try o.remove("d/leaf")
        try o.remove("d")
        try o.mkdir("d", mode: 0o755)
        let names = try o.readdir("d").map { $0.name }
        XCTAssertEqual(names, [])
    }

    // MARK: helpers

    private func mkTemp(_ label: String) -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghwt-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func writeFile(at path: String, _ s: String) throws {
        try s.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }
}
