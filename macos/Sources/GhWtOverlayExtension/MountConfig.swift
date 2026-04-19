import Foundation
import FSKit

/// Encoding of the lower / upper paths the helper CLI hands to the extension.
///
/// `gh-wt-mount-overlay` packs them into the `taskOptions` task-info dict
/// when it sends the mount request to fskitd. The keys below are part of the
/// public contract between the helper and the extension; bumping them is a
/// breaking change for in-flight mounts.
public struct OverlayMountConfig {
    public let lower: String
    public let upper: String
    public let volumeName: String

    public static let lowerKey      = "gh-wt.lower"
    public static let upperKey      = "gh-wt.upper"
    public static let volumeNameKey = "gh-wt.volumeName"

    public static func decode(from resource: FSResource, options: FSTaskOptions) throws -> OverlayMountConfig {
        // FSTaskOptions is the documented place for caller-provided
        // key/value pairs. The exact accessor name has shifted between
        // FSKit revisions (`taskInfoDictionary` vs `userInfo`); we read
        // both via NSDictionary KVC to be revision-agnostic.
        let bag = (options as AnyObject).value(forKey: "taskInfoDictionary") as? [String: Any]
            ?? (options as AnyObject).value(forKey: "userInfo") as? [String: Any]
            ?? [:]

        guard let lower = bag[lowerKey] as? String else {
            throw OverlayConfigError.missingKey(lowerKey)
        }
        guard let upper = bag[upperKey] as? String else {
            throw OverlayConfigError.missingKey(upperKey)
        }
        let name = (bag[volumeNameKey] as? String) ?? "gh-wt-overlay"
        return OverlayMountConfig(lower: lower, upper: upper, volumeName: name)
    }
}

public enum OverlayConfigError: Error, CustomStringConvertible {
    case missingKey(String)
    public var description: String {
        switch self {
        case .missingKey(let k): return "mount config missing key: \(k)"
        }
    }
}
