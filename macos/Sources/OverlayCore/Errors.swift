import Foundation

/// Errors raised by OverlayCore. Each carries a POSIX errno so callers (the
/// FSKit volume in particular) can translate to the right kernel reply.
public struct OverlayError: Error, Equatable, CustomStringConvertible {
    public let errno: Int32
    public let detail: String

    public init(_ errno: Int32, _ detail: String = "") {
        self.errno = errno
        self.detail = detail
    }

    public var description: String {
        let name = String(cString: strerror(errno))
        return detail.isEmpty ? name : "\(name): \(detail)"
    }

    public static let notFound       = OverlayError(ENOENT)
    public static let alreadyExists  = OverlayError(EEXIST)
    public static let notADirectory  = OverlayError(ENOTDIR)
    public static let isADirectory   = OverlayError(EISDIR)
    public static let notEmpty       = OverlayError(ENOTEMPTY)
    public static let invalid        = OverlayError(EINVAL)
    public static let permission     = OverlayError(EACCES)
    public static let crossDevice    = OverlayError(EXDEV)
}

/// Throws `OverlayError(errno)` if `result < 0`.
@discardableResult
internal func posix(_ tag: String, _ result: Int32) throws -> Int32 {
    if result < 0 {
        throw OverlayError(errno, tag)
    }
    return result
}

@discardableResult
internal func posix(_ tag: String, _ result: Int) throws -> Int {
    if result < 0 {
        throw OverlayError(errno, tag)
    }
    return result
}
