//===----------------------------------------------------------------------===//
//
//  Event.swift / Events.swift
//  MIO
//
//  A single readiness notification (`Event`) and a capacity-bounded
//  collection that the kernel fills directly (`Events`). Mirrors
//  `mio::event::{Event, Events}` (rust).
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import CMIO

#if canImport(Glibc)
import Glibc
#endif

/// A single readiness notification delivered by `Poll.poll`.
///
/// `Event` is a value type: copying it is O(1). It exposes the `Token`
/// the caller registered alongside the source and a `Ready` bitset
/// describing what the kernel observed.
@frozen
public struct Event: Sendable, Hashable, CustomStringConvertible {
    /// The user-supplied identifier of the source that became ready.
    public let token: Token
    /// The readiness conditions reported by the kernel.
    public let ready: Ready

    @inlinable
    public init(token: Token, ready: Ready) {
        self.token = token
        self.ready = ready
    }

    @inlinable
    public var isReadable: Bool { ready.isReadable }
    @inlinable
    public var isWritable: Bool { ready.isWritable }
    @inlinable
    public var isError: Bool { ready.isError }
    @inlinable
    public var isHangup: Bool { ready.isHangup }
    @inlinable
    public var isPriority: Bool { ready.contains(.priority) }
    @inlinable
    public var isReadClosed: Bool { ready.isReadClosed }
    @inlinable
    public var isWriteClosed: Bool { ready.isWriteClosed }

    public var description: String { "Event(\(token), \(ready))" }
}

/// A capacity-bounded, reusable container for `Event`s.
///
/// `Events` owns a single contiguous buffer of `sl_epoll_event` records
/// that `epoll_wait(2)` writes into directly — zero allocation per poll.
/// Call `clear()` between iterations (costs one int store).
///
/// **Threading contract:** `Events` is intentionally **not** `Sendable`.
/// It is meant to be stack-allocated (or held in a single-thread field)
/// on the worker thread that calls `Poll.poll`. The kernel writes the
/// delivered-event count into `_count` on each poll; concurrent reads
/// from another thread would race. If you need to share an `Events`
/// across threads, wrap it in `Mutex<Events>` (from `Synchronization`)
/// — but you almost certainly want one `Events` per worker instead.
public final class Events {

    // Raw kernel-write buffer. Allocated once, lives for the lifetime of
    // the container. 12 bytes per slot.
    //
    // `@usableFromInline` so the `@inlinable` `forEach`/`subscript` below
    // (consumed across the module boundary by hot loops in e.g. an event
    // loop) can read it directly without a per-element accessor call.
    @usableFromInline internal let buffer: UnsafeMutablePointer<sl_epoll_event>
    public let capacity: Int

    // Number of valid records currently in `buffer`. Set by `Poll.poll`.
    @usableFromInline internal var _count: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "Events capacity must be > 0")
        // Round up to at least one cache line's worth (16 × 12 B = 192 B) to
        // amortise allocation; epoll_wait will still only fill up to the
        // requested capacity.
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
        // Poison with zeros so a missed clear() never surfaces a stale
        // token from a previous process's memory.
        buffer.initialize(repeating: sl_epoll_event(), count: capacity)
    }

    deinit {
        // `sl_epoll_event` is a trivial C struct (no retainable members),
        // so `deinitialize` is technically a no-op — but paired with the
        // `initialize` above for symmetry and to keep the pointer pattern
        // safe under future changes to the element type.
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    @inlinable
    public var isEmpty: Bool { _count == 0 }
    @inlinable
    public var count: Int { _count }

    /// Reset the visible event count to zero. Does not scrub the buffer —
    /// the kernel will overwrite entries on the next `poll`. O(1).
    @inlinable
    public func clear() { _count = 0 }

    /// Access the i-th event. Traps on out-of-bounds `position`
    /// (debug: assertion; release: traps via UnsafeMutablePointer).
    ///
    /// Performance: the precondition is checked even in release builds
    /// because the kernel-fed `_count` is the only correctness boundary
    /// — a stale or wrong `position` from a caller would otherwise read
    /// uninitialised memory. The check is a single compare+branch per
    /// access, dominated by the cost of the surrounding work.
    @inlinable
    public subscript(position: Int) -> Event {
        precondition(position >= 0 && position < _count,
            "Events.subscript: position \(position) out of range 0..<\(_count)")
        let raw = buffer[position]
        return Event(token: Token(raw.data), ready: Ready(rawValue: raw.events))
    }

    /// Iterate delivered events. Equivalent to mio's `Events::iter`.
    ///
    /// `@inlinable` so the per-event dispatch closure supplied by an event
    /// loop is inlined into the loop body, avoiding an indirect call per
    /// event across the module boundary.
    @inlinable
    public func forEach(_ body: (Event) -> Void) {
        for i in 0..<_count {
            let raw = buffer[i]
            body(Event(token: Token(raw.data), ready: Ready(rawValue: raw.events)))
        }
    }

    /// Returns an array copy of the delivered events. Use sparingly —
    /// prefer `forEach(_:)` to avoid allocation in the hot path.
    public func toArray() -> [Event] {
        var out: [Event] = []
        out.reserveCapacity(_count)
        forEach { out.append($0) }
        return out
    }

    // ── Internal: used by Poll to write into the raw buffer ─────────────

    @usableFromInline
    internal var _rawBuffer: UnsafeMutablePointer<sl_epoll_event> { buffer }

    @usableFromInline
    internal func _setDeliveredCount(_ n: Int) {
        precondition(n >= 0 && n <= capacity)
        _count = n
    }
}

#endif // os(Linux)
