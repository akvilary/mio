//===----------------------------------------------------------------------===//
//
//  Interest.swift
//  MIO
//
//  Interest of a registration — what the caller wants to be notified about.
//  Mirrors `mio::Interest` (rust). Direct 1:1 mapping to epoll event bits.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

/// The set of I/O events a source is interested in being notified about.
///
/// `Interest` is an `OptionSet` over the raw 32-bit `epoll_event.events`
/// field, so callers may combine, intersect and test bits directly:
///
/// ```swift
/// let both: Interest = [.readable, .writable]
/// if both.contains(.readable) { ... }
/// ```
///
/// Two modifiers are supported in addition to the readiness bits:
///
///   - `.edge`     — adds `EPOLLET`, edge-triggered. The default is
///                   level-triggered, matching mio's portability stance.
///   - `.oneshot`  — adds `EPOLLONESHOT`. The source is auto-disabled
///                   after the first event and must be re-armed via
///                   `Registry.reregister`. This is the natural model for
///                   the async one-shot read/write API used by
///                   `PollEventLoop`.
@frozen
public struct Interest: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    // ── Readiness bits ─────────────────────────────────────────────────
    //
    // These map 1:1 onto the kernel's EPOLL constants and must not be
    // renumbered.

    /// Notify when the source is readable (`EPOLLIN`). `EPOLLRDHUP` is
    /// added automatically at registration time (see `_epollBits`), so
    /// peer half-close surfaces via `Event.isReadClosed`.
    public static let readable = Interest(rawValue: 0x001)

    /// Notify when the source is writable (`EPOLLOUT`).
    public static let writable = Interest(rawValue: 0x004)

    /// Out-of-band / urgent data available (`EPOLLPRI`).
    public static let priority = Interest(rawValue: 0x002)

    // ── Triggering modifiers ───────────────────────────────────────────

    /// Edge-triggered. By default registrations are level-triggered.
    public static let edge = Interest(rawValue: 0x8000_0000)

    /// One-shot: deliver at most one event, then auto-disable the source
    /// until re-armed via `Registry.reregister`.
    public static let oneshot = Interest(rawValue: 0x4000_0000)

    /// Exclusive wakeups (`EPOLLEXCLUSIVE`, Linux 4.5+). When multiple
    /// epolls (or multiple threads sharing one epoll via `Poll.registry`)
    /// register the same fd with `.exclusive`, the kernel delivers each
    /// event to **at most one** waiter — preventing thundering herd on
    /// the accept path. Mutually beneficial with `SO_REUSEPORT` but the
    /// primary use case is **shared-listener** multi-process servers
    /// (where `SO_REUSEPORT` is unavailable or undesirable).
    ///
    /// Restrictions (kernel-imposed):
    ///   - May NOT be combined with `.edge`; must be level-triggered.
    ///   - May NOT be set via `reregister` — must be present at the
    ///     initial `register` call (the kernel silently ignores later
    ///     attempts to add it).
    ///   - The kernel whitelist for `EPOLLEXCLUSIVE` is exactly
    ///     `EPOLLIN | EPOLLOUT`: the auto-added `EPOLLRDHUP` is
    ///     suppressed for `.exclusive` registrations, so
    ///     `Event.isReadClosed` will not fire for them.
    ///   - For `accept(2)`-style events only — semantics with `read`/
    ///     `write` are not what most callers expect (events may still
    ///     queue if the same fd is registered multiple times).
    public static let exclusive = Interest(rawValue: 0x1000_0000)

    // ── Convenience compositions ───────────────────────────────────────

    /// Both readable and writable. Convenience for `[.readable, .writable]`.
    public static let both: Interest = [.readable, .writable]

    /// Mask of the readiness bits. Useful when stripping modifier bits
    /// before comparing or persisting.
    public static let readinessMask: Interest = [.readable, .writable, .priority]

    // ── Kernel mapping ─────────────────────────────────────────────────

    /// Raw epoll `events` bits used when registering this interest.
    ///
    /// Mirrors mio's `interests_to_epoll`: `EPOLLRDHUP` rides along with
    /// `EPOLLIN` so peer half-close is observable in delivered events
    /// (`Event.isReadClosed`). Without it the kernel never reports the
    /// RDHUP bit and half-close is indistinguishable from ordinary
    /// readability.
    ///
    /// Exception: `.exclusive` registrations. The kernel's
    /// `EPOLLEXCLUSIVE` whitelist is exactly `EPOLLIN | EPOLLOUT` —
    /// adding `EPOLLRDHUP` fails the whole `epoll_ctl` with `EINVAL`
    /// (verified on Linux 6.17; the restriction has existed since the
    /// flag's introduction in 4.5). Half-close detection is therefore
    /// unavailable for shared-listener registrations — acceptable
    /// because accept-ready listeners are closed wholesale, not
    /// half-closed.
    internal var _epollBits: UInt32 {
        var bits = rawValue
        if contains(.readable) && !contains(.exclusive) {
            bits |= Ready.readHangup.rawValue // EPOLLRDHUP (0x2000)
        }
        return bits
    }

    @inlinable
    public var isReadable: Bool { contains(.readable) }

    @inlinable
    public var isWritable: Bool { contains(.writable) }

    @inlinable
    public var isEdge: Bool { contains(.edge) }

    @inlinable
    public var isOneshot: Bool { contains(.oneshot) }

    @inlinable
    public var isExclusive: Bool { contains(.exclusive) }

    public var description: String {
        var parts: [String] = []
        if isReadable { parts.append("readable") }
        if isWritable { parts.append("writable") }
        if contains(.priority) { parts.append("priority") }
        if isEdge { parts.append("edge") }
        if isOneshot { parts.append("oneshot") }
        if isExclusive { parts.append("exclusive") }
        return "Interest(\(parts.joined(separator: " | ")))"
    }
}

#endif // os(Linux)
