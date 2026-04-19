import XCTest
@testable import OverlayCore

final class MountURLTests: XCTestCase {
    func testRoundTrip() throws {
        let cfg = OverlayMountURL.Config(
            lower: "/var/cache/gh-wt/ref/abc",
            upper: "/var/cache/gh-wt/sessions/s1/upper",
            volumeName: "feature-x"
        )
        let url = OverlayMountURL.build(cfg)
        XCTAssertEqual(url.scheme, "gh-wt-overlay")
        let decoded = try OverlayMountURL.decode(url)
        XCTAssertEqual(decoded, cfg)
    }

    func testPercentEncodedPaths() throws {
        let cfg = OverlayMountURL.Config(
            lower: "/tmp/a b/with spaces",
            upper: "/tmp/hash#fragment/plus+eq=",
            volumeName: "name with space"
        )
        let decoded = try OverlayMountURL.decode(OverlayMountURL.build(cfg))
        XCTAssertEqual(decoded, cfg)
    }

    func testMissingParameterRejected() {
        let bad = URL(string: "gh-wt-overlay:///mount?lower=/a")!
        XCTAssertThrowsError(try OverlayMountURL.decode(bad)) { err in
            guard case OverlayMountURL.DecodeError.missingParameter(let k) = err else {
                return XCTFail("unexpected error: \(err)")
            }
            XCTAssertEqual(k, "upper")
        }
    }

    func testWrongSchemeRejected() {
        let bad = URL(string: "file:///tmp")!
        XCTAssertThrowsError(try OverlayMountURL.decode(bad)) { err in
            guard case OverlayMountURL.DecodeError.wrongScheme = err else {
                return XCTFail("unexpected error: \(err)")
            }
        }
    }

    func testDefaultVolumeNameWhenEmpty() throws {
        var comps = URLComponents()
        comps.scheme = "gh-wt-overlay"
        comps.host = ""
        comps.path = "/mount"
        comps.queryItems = [
            URLQueryItem(name: "lower", value: "/l"),
            URLQueryItem(name: "upper", value: "/u"),
        ]
        let decoded = try OverlayMountURL.decode(comps.url!)
        XCTAssertEqual(decoded.volumeName, "gh-wt-overlay")
    }
}
