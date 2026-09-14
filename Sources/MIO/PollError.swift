//===----------------------------------------------------------------------===//
//
//  PollError.swift
//  MIO
//
//  Error surface of the poll module. Mirrors `std::io::Error` as exposed
//  by mio (rust): a raw errno plus the failing syscall name.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

#if canImport(Glibc)
import Glibc
#endif

/// An error raised by a `Poll`/`Registry`/`Waker` operation.
///
/// Carries the raw `errno` value and the name of the failing syscall so
/// that production logs are self-explanatory without consulting the
/// source. `code` is the raw errno value (`Int32`) — never the negated
/// form used internally by the C wrappers. `function` is a
/// `StaticString` (always a compile-time literal at every call site), so
/// constructing an error performs no allocation.
public struct PollError: Error, Sendable, CustomStringConvertible, Equatable {
    /// Raw errno value (positive, matching the C `errno` convention).
    public let code: Int32
    /// Name of the failing syscall (e.g. "epoll_wait", "eventfd").
    public let function: StaticString

    @inlinable
    public init(code: Int32, function: StaticString) {
        self.code = code
        self.function = function
    }

    /// Construct from the **negative return value** of the `sl_*` C
    /// wrappers, which return `-errno` directly. Preferred over
    /// `fromErrno(function:)` because the C wrapper captures `errno`
    /// before any subsequent Swift-runtime syscall can clobber it.
    @inlinable
    public static func fromNegativeReturn(_ value: CInt, function: StaticString) -> PollError {
        // value is < 0; the errno is `-value`.
        precondition(value < 0, "fromNegativeReturn called with non-negative value")
        return PollError(code: Int32(-value), function: function)
    }

    /// Construct from the thread-local `errno`. **Fragile** — any
    /// intervening syscall on this thread (including Swift-runtime
    /// internal calls) will clobber `errno` before this runs. Prefer
    /// `fromNegativeReturn(_:_:)` for any error originating from a
    /// `sl_*` wrapper that returns `-errno`.
    ///
    /// Kept for callers wrapping syscalls directly (e.g. `socketpair`
    /// in tests).
    public static func fromErrno(function: StaticString) -> PollError {
        return PollError(code: Int32(errno), function: function)
    }

    public var description: String {
        // strerror is not async-signal-safe but is fine on a normal Swift
        // call path. Buffer-copy via Swift String to avoid any lifetime
        // issues with the static buffer.
        let msg = String(cString: strerror(code))
        return "PollError(\(function)): \(msg) [errno \(code)]"
    }

    public static func == (lhs: PollError, rhs: PollError) -> Bool {
        // StaticString is not itself Equatable; compare code plus the
        // literal's contents. Errors are a cold path, so the transient
        // string comparison here is irrelevant.
        lhs.code == rhs.code
            && String(describing: lhs.function) == String(describing: rhs.function)
    }
}

#endif // os(Linux)
