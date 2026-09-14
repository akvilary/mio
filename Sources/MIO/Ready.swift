//===----------------------------------------------------------------------===//
//
//  Ready.swift
//  MIO
//
//  Ready is the output counterpart of Interest — it describes which
//  readiness conditions were actually observed for a delivered event.
//  Mirrors `mio::event::Ready` (rust) minus the deprecated AIO/LIO bits
//  (unsupported on epoll).
//
//===----------------------------------------------------------------------===//

#if os(Linux)

/// The readiness conditions observed for a delivered event.
///
/// `Ready` is what the kernel actually reports, which is a superset of
/// what was registered: an `Interest.readable` registration may surface
/// `error`, `hangup`, or `readClosed` as well. Always test these flags
/// explicitly rather than assuming only the requested bits are present.
@frozen
public struct Ready: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let readable     = Ready(rawValue: 0x001)  // EPOLLIN
    public static let writable     = Ready(rawValue: 0x004)  // EPOLLOUT
    public static let priority     = Ready(rawValue: 0x002)  // EPOLLPRI
    public static let error        = Ready(rawValue: 0x008)  // EPOLLERR
    public static let hangup       = Ready(rawValue: 0x010)  // EPOLLHUP
    public static let readHangup   = Ready(rawValue: 0x2000) // EPOLLRDHUP

    /// Read-side EOF. Mirrors mio's `is_read_closed` on epoll exactly:
    ///
    ///   - `hangup` — both halves of the peer closed, or
    ///   - `readable && readHangup` — FIN received (possibly with
    ///     unread data still buffered) or `shutdown(SHUT_RD)`.
    ///
    /// `readHangup` is only ever reported because `Registry.register`
    /// adds `EPOLLRDHUP` to `.readable` registrations (mio parity).
    @inlinable
    public var isReadClosed: Bool {
        isHangup || (contains(.readable) && contains(.readHangup))
    }

    /// Write-side EOF. Mirrors mio's `is_write_closed` on epoll exactly:
    ///
    ///   - `hangup` — both halves closed, or
    ///   - `writable && error` — Unix pipe read end closed, or
    ///   - the event mask is *exactly* `error` (nothing but EPOLLERR —
    ///     the other side of a Unix pipe has closed).
    ///
    /// Note: the local side shutting down its write half does NOT
    /// trigger this on epoll (same as mio).
    @inlinable
    public var isWriteClosed: Bool {
        isHangup
            || (contains(.writable) && isError)
            || rawValue == Ready.error.rawValue
    }

    /// Readable, including out-of-band/priority data. Mirrors mio's
    /// `is_readable` on epoll: `EPOLLIN || EPOLLPRI`. Folding OOB into
    /// readable is deliberate (see the DoS note in mio's docs): apps
    /// that never read OOB data would otherwise sit on a permanently
    /// ready source.
    @inlinable
    public var isReadable: Bool   { contains(.readable) || contains(.priority) }
    @inlinable
    public var isWritable: Bool   { contains(.writable) }
    @inlinable
    public var isError: Bool      { contains(.error) }
    @inlinable
    public var isHangup: Bool     { contains(.hangup) }

    public var description: String {
        var parts: [String] = []
        if isReadable { parts.append("readable") }
        if isWritable { parts.append("writable") }
        if contains(.priority) { parts.append("priority") }
        if isError { parts.append("error") }
        if isHangup { parts.append("hangup") }
        if contains(.readHangup) { parts.append("readHangup") }
        return "Ready(\(parts.joined(separator: " | ")))"
    }
}

#endif // os(Linux)
