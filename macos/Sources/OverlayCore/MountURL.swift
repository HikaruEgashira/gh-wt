import Foundation

/// Canonical URL encoding shared between the helper CLI and the FSKit
/// extension. The extension declares `gh-wt-overlay` under
/// `FSSupportedSchemes` in its Info.plist, so FSKit constructs an
/// `FSGenericURLResource` from a URL of this shape and hands it to the
/// extension's `loadResource`. The helper CLI builds the same URL and
/// dispatches via `mount(8) -t gh-wt-overlay`.
///
/// Single encoding, single parser, one contract — no parallel KVC path,
/// no JSON-over-taskInfoDictionary workaround.
public enum OverlayMountURL {
    public static let scheme = "gh-wt-overlay"

    public struct Config: Equatable, Sendable {
        public let lower: String
        public let upper: String
        public let volumeName: String

        public init(lower: String, upper: String, volumeName: String) {
            self.lower = lower
            self.upper = upper
            self.volumeName = volumeName
        }
    }

    public enum DecodeError: Error, CustomStringConvertible {
        case wrongScheme(String?)
        case missingParameter(String)
        public var description: String {
            switch self {
            case .wrongScheme(let s): return "expected scheme \(scheme), got \(s ?? "<nil>")"
            case .missingParameter(let k): return "mount URL missing parameter: \(k)"
            }
        }
    }

    public static func build(_ cfg: Config) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = ""
        comps.path = "/mount"
        comps.queryItems = [
            URLQueryItem(name: "lower", value: cfg.lower),
            URLQueryItem(name: "upper", value: cfg.upper),
            URLQueryItem(name: "name",  value: cfg.volumeName),
        ]
        return comps.url!
    }

    public static func decode(_ url: URL) throws -> Config {
        guard url.scheme == scheme else {
            throw DecodeError.wrongScheme(url.scheme)
        }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DecodeError.missingParameter("<components>")
        }
        let items = comps.queryItems ?? []
        func required(_ key: String) throws -> String {
            guard let v = items.first(where: { $0.name == key })?.value, !v.isEmpty else {
                throw DecodeError.missingParameter(key)
            }
            return v
        }
        let lower = try required("lower")
        let upper = try required("upper")
        let name  = (items.first(where: { $0.name == "name" })?.value).flatMap { $0.isEmpty ? nil : $0 } ?? "gh-wt-overlay"
        return Config(lower: lower, upper: upper, volumeName: name)
    }
}
