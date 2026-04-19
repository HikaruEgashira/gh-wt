// Doctor.swift — surface diagnostics for `gh wt doctor` on macOS.

import Foundation

enum Doctor {
    static func run() {
        var ok = true
        ok = check("macOS 26+", { macOSMajor() >= 26 }) && ok
        ok = check("fskit_load CLI present", { FileManager.default.isExecutableFile(atPath: "/usr/sbin/fskit_load") }) && ok
        ok = check("FSKit framework present", { FileManager.default.fileExists(atPath: "/System/Library/Frameworks/FSKit.framework") }) && ok
        ok = check("gh-wt-overlay extension activated", isExtensionActivated) && ok

        if !ok {
            FileHandle.standardError.write(Data("\nSee macos/README.md for setup instructions.\n".utf8))
            exit(1)
        }
    }

    private static func check(_ label: String, _ probe: () -> Bool) -> Bool {
        let pass = probe()
        let mark = pass ? "✓" : "✗"
        print("  \(mark) \(label)")
        return pass
    }

    private static func macOSMajor() -> Int {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion
    }

    private static func isExtensionActivated() -> Bool {
        // `systemextensionsctl list` returns activated extensions. We just
        // grep for our bundle id; if systemextensionsctl is missing, treat
        // as a soft fail rather than a hard one.
        let p = Process()
        p.launchPath = "/usr/bin/systemextensionsctl"
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.contains(MountClient.bundleID)
    }
}
