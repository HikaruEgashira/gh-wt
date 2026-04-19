import Foundation
import FSKit
import OverlayCore

/// Extract the overlay configuration from the `FSResource` that FSKit
/// hands us. We register the `gh-wt-overlay` URL scheme via
/// `FSSupportedSchemes` in Info.plist, so FSKit constructs an
/// `FSGenericURLResource` from the URL passed on the `mount(8)` command
/// line and delivers it here. See `OverlayMountURL` for the URL shape.
public enum OverlayMountConfigDecoder {
    public static func decode(from resource: FSResource) throws -> OverlayMountURL.Config {
        guard let urlResource = resource as? FSGenericURLResource else {
            throw OverlayConfigError.unsupportedResource(String(describing: type(of: resource)))
        }
        return try OverlayMountURL.decode(urlResource.url)
    }
}

public enum OverlayConfigError: Error, CustomStringConvertible {
    case unsupportedResource(String)
    public var description: String {
        switch self {
        case .unsupportedResource(let t): return "unsupported FSResource type: \(t)"
        }
    }
}
