// FirstTouchBench/main.swift
//
// Standalone executable that measures the work an FPE extension would
// do on every fetchContents(): URL construction, parent-dir creation,
// stale-removal, clonefile(2), attribute read. This is the "our code"
// cost that sits on top of the kernel floor and below the FPE RPC
// overhead.
//
// Usage: FirstTouchBench <src_dir> <dst_dir> <iterations>
//   src_dir must already contain <iterations> files named f0..f<n>.
//
// Output (one line of TSV to stdout):
//   iterations  total_ns  per_call_ns  ops_per_sec

import Foundation

@_silgen_name("clonefile")
func clonefile(_ src: UnsafePointer<CChar>,
               _ dst: UnsafePointer<CChar>,
               _ flags: UInt32) -> Int32

func materialise(srcURL: URL, dstURL: URL) throws {
    try FileManager.default.createDirectory(
        at: dstURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    _ = try? FileManager.default.removeItem(at: dstURL)
    let rc = clonefile(srcURL.path, dstURL.path, 0)
    if rc != 0 {
        throw NSError(domain: NSPOSIXErrorDomain,
                      code: Int(errno),
                      userInfo: [NSLocalizedDescriptionKey:
                                 "clonefile failed: \(String(cString: strerror(errno)))"])
    }
    _ = try FileManager.default.attributesOfItem(atPath: dstURL.path)
}

let args = CommandLine.arguments
guard args.count == 4,
      let n = Int(args[3]) else {
    FileHandle.standardError.write(
        "usage: FirstTouchBench <src_dir> <dst_dir> <iterations>\n".data(using: .utf8)!)
    exit(2)
}
let srcDir = URL(fileURLWithPath: args[1], isDirectory: true)
let dstDir = URL(fileURLWithPath: args[2], isDirectory: true)
try? FileManager.default.removeItem(at: dstDir)
try FileManager.default.createDirectory(at: dstDir,
                                        withIntermediateDirectories: true)

// warm-up (not measured): file system cache + dynamic linker paths.
for i in 0..<min(50, n) {
    let src = srcDir.appendingPathComponent("f\(i)")
    let dst = dstDir.appendingPathComponent("warm-\(i)")
    try materialise(srcURL: src, dstURL: dst)
}

let t0 = DispatchTime.now().uptimeNanoseconds
for i in 0..<n {
    let src = srcDir.appendingPathComponent("f\(i)")
    let dst = dstDir.appendingPathComponent("measured-\(i)")
    try materialise(srcURL: src, dstURL: dst)
}
let t1 = DispatchTime.now().uptimeNanoseconds

let totalNs = Int64(t1 - t0)
let perCall = totalNs / Int64(n)
let opsPerSec = Int64(n) * 1_000_000_000 / totalNs
print("\(n)\t\(totalNs)\t\(perCall)\t\(opsPerSec)")
