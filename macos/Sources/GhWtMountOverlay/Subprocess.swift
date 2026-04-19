import Foundation
import OverlayCore

enum Subprocess {
    static func run(_ launchPath: String, _ args: [String]) throws {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { throw OverlayError(EIO, "exec \(launchPath): \(error)") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? "<no stderr>"
            throw OverlayError(EIO, "\(launchPath) exited \(p.terminationStatus): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
