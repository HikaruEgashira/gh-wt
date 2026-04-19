// gh-wt-mount-overlay — userland front-end to the gh-wt-overlay FSKit
// System Extension.
//
// Usage:
//   gh-wt-mount-overlay mount   [--backend fskit] --lower L --upper U --mountpoint M
//   gh-wt-mount-overlay unmount [--backend fskit] --mountpoint M
//   gh-wt-mount-overlay list-lowers
//   gh-wt-mount-overlay doctor
//
// --backend is accepted for shell-side symmetry with the macFUSE helper
// (gh-wt-mount-overlay-fuse). Only `fskit` is valid here; `macfuse` is
// rejected with a hint so the dispatcher bug is caught loudly instead of
// silently mounting via the wrong backend.
//
// The first three are called from `lib/overlay.sh` on Darwin. `doctor` is
// surfaced as `gh wt doctor` for users to verify their setup.

import Foundation
import OverlayCore

let argv = CommandLine.arguments

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      gh-wt-mount-overlay mount   [--backend fskit] --lower <dir> --upper <dir> --mountpoint <dir>
      gh-wt-mount-overlay unmount [--backend fskit] --mountpoint <dir>
      gh-wt-mount-overlay list-lowers
      gh-wt-mount-overlay doctor
    """.utf8))
    exit(2)
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("gh-wt-mount-overlay: \(msg)\n".utf8))
    exit(1)
}

guard argv.count >= 2 else { usage() }

func requireFskitBackend(_ opts: [String: String]) {
    guard let backend = opts["--backend"] else { return }
    switch backend {
    case "fskit":
        return
    case "macfuse":
        die("--backend macfuse is served by gh-wt-mount-overlay-fuse, not this binary")
    default:
        die("unknown --backend: \(backend) (expected fskit)")
    }
}

do {
    switch argv[1] {
    case "mount":
        let opts = parseFlags(Array(argv.dropFirst(2)), required: ["--lower", "--upper", "--mountpoint"])
        requireFskitBackend(opts)
        try MountClient.mount(lower: opts["--lower"]!, upper: opts["--upper"]!, mountpoint: opts["--mountpoint"]!)
    case "unmount":
        let opts = parseFlags(Array(argv.dropFirst(2)), required: ["--mountpoint"])
        requireFskitBackend(opts)
        try MountClient.unmount(mountpoint: opts["--mountpoint"]!)
    case "list-lowers":
        for lower in MountRegistry.shared.liveLowers() {
            print(lower)
        }
    case "doctor":
        Doctor.run()
    case "-h", "--help":
        usage()
    default:
        usage()
    }
} catch let err as OverlayError {
    die(String(describing: err))
} catch {
    die(String(describing: error))
}

func parseFlags(_ argv: [String], required: [String]) -> [String: String] {
    var out: [String: String] = [:]
    var i = 0
    while i < argv.count {
        let k = argv[i]
        guard k.hasPrefix("--") else { die("unexpected arg: \(k)") }
        guard i + 1 < argv.count else { die("missing value for \(k)") }
        out[k] = argv[i + 1]
        i += 2
    }
    for k in required where out[k] == nil {
        die("missing required flag: \(k)")
    }
    return out
}
