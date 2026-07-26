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
/// **Ownership model (Swift 6.2):** `Events` is **move-only** (`~Copyable`)
/// and **not** `Sendable`. The compiler enforces single-owner single-thread
/// access at compile time — an `Events` value cannot be aliased, copied
/// into a closure escape, or shared across actor boundaries. This is the
/// idiomatic Swift 6.2 expression of the single-thread contract that
/// `@unchecked Sendable` previously claimed (without proof) on the
/// class form.
///
/// Concretely:
///   - Construct one `Events` per worker thread.
///   - Pass it to `Poll.poll(_:timeout:)` via `inout`:
///     `try poll.poll(&events, timeout: .blocking)`.
///   - Iterate via `forEach` (borrowing) or `subscript` (borrowing).
///   - Mutate via `clear()` or another `poll` call (both `mutating`).
///   - On scope exit, the `consuming deinit` releases the kernel-write
///     buffer automatically — no explicit deallocation required.
public struct Events: ~Copyable {
    // Raw kernel-write buffer. Allocated once, lives for the lifetime of
    // the value. 12 bytes per slot.
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
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
        // Poison with zeros so a missed clear() never surfaces a stale
        // token from a previous process's memory.
        buffer.initialize(repeating: sl_epoll_event(), count: capacity)
    }

    /// Releases the kernel-write buffer. Invoked automatically when the
    /// value goes out of scope or its owning class (e.g. `PollEventLoop`)
    /// deinitializes. For a `~Copyable` struct, `deinit` is implicitly
    /// consuming — the value is destroyed after this runs.
    ///
    /// `sl_epoll_event` is a trivial C struct, so the `deinitialize` is
    /// a no-op in practice — kept for symmetry with the `initialize`
    /// above and forward-safety if the element type ever carries
    /// retainable members.
    deinit {
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
    public mutating func clear() { _count = 0 }

    /// Access the i-th event. Traps on out-of-bounds `position`
    /// (debug: assertion; release: traps via UnsafeMutablePointer).
    ///
    /// Performance: the precondition is checked even in release builds
    /// because the kernel-fed `_count` is the only correctness boundary
    /// — a stale or wrong `position` from a caller would otherwise read
    /// uninitialised memory. The check is a single compare+branch per
    /// access, dominated by the cost of the surrounding work.
    ///
    /// Read-only subscripts on a `~Copyable` struct borrow `self` for
    /// the duration of the access — the caller retains ownership.
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
    /// event across the module boundary. Borrowing: the iteration does
    /// not consume `self`; the caller retains ownership for a subsequent
    /// `poll` or `clear`.
    @inlinable
    public borrowing func forEach(_ body: (Event) -> Void) {
        for i in 0..<_count {
            let raw = buffer[i]
            body(Event(token: Token(raw.data), ready: Ready(rawValue: raw.events)))
        }
    }

    /// Returns an array copy of the delivered events. Use sparingly —
    /// prefer `forEach(_:)` to avoid allocation in the hot path.
    ///
    /// Borrowing: the source `Events` remains usable after this call.
    public borrowing func toArray() -> [Event] {
        var out: [Event] = []
        out.reserveCapacity(_count)
        forEach { out.append($0) }
        return out
    }

    // ── Internal: used by Poll to write into the raw buffer ─────────────

    /// Pointer to the kernel-write buffer. **Unsafe:** the returned
    /// pointer is valid only while the borrowing caller holds `self`
    /// alive; do not escape it across the call's lifetime.
    @usableFromInline
    internal var _rawBuffer: UnsafeMutablePointer<sl_epoll_event> { buffer }

    @usableFromInline
    internal mutating func _setDeliveredCount(_ n: Int) {
        precondition(n >= 0 && n <= capacity)
        _count = n
    }

    // ── Poll integration ──────────────────────────────────────────────
    //
    // `wait(on:timeout:)` is a `mutating` method on `Events` itself
    // (not an extension) because `~Copyable` types' extension methods
    // are not reliably visible across module boundaries in current
    // Swift 6.2. Inlining the methods into the type declaration makes
    // them part of the canonical interface and exportable normally.
    //
    // The methods need `epfd` from `Poll`; they take it as a parameter
    // rather than capturing `Poll` to keep `Events` independent of the
    // `Poll` type's storage layout.

    /// Block until at least one registered source becomes ready, then
    /// write up to `capacity` events into `self`. Returns the number
    /// of delivered events (0 on timeout).
    ///
    /// **Blocking syscall.** Calls `epoll_wait(2)`, which may block
    /// indefinitely with `timeout: .blocking`. Do NOT call from Swift's
    /// cooperative thread pool — use a dedicated `Thread` or an actor
    /// with a custom `SerialExecutor` (see `PollEventLoop` in the
    /// `starlight` package for a reference implementation).
    ///
    /// `EINTR` is retried automatically; all other errors surface as
    /// `PollError`.
    ///
    /// **Timeout caveat:** the EINTR retry does NOT account for time
    /// already spent blocked before the signal. A `.milliseconds(5000)`
    /// interrupted at 4999 ms will re-block for another 5000 ms. For
    /// precise timeout accounting, use `.immediate` + your own clock.
    @discardableResult
    public mutating func wait(
        on poll: Poll,
        timeout: PollTimeout = .blocking
    ) throws -> Int {
        while true {
            let n = sl_epoll_wait(
                poll.epfd,
                _rawBuffer,
                CInt(capacity),
                timeout.rawMilliseconds
            )
            if n >= 0 {
                _setDeliveredCount(Int(n))
                return Int(n)
            }
            let err = -n
            if err == EINTR { continue }
            _setDeliveredCount(0)
            throw PollError(code: Int32(err), function: "epoll_wait")
        }
    }

    /// Nanosecond-resolution variant of `wait`. Uses `epoll_pwait2`
    /// (Linux 5.11+); on older kernels (or any `ENOSYS` from the
    /// kernel), silently falls back to millisecond truncation via
    /// `epoll_wait`. `sigmask` may be `nil` for no signal-mask change.
    ///
    /// Same blocking-syscall caveat as `wait(on:timeout:)`.
    @discardableResult
    public mutating func waitNano(
        on poll: Poll,
        timeout: PollTimeout,
        sigmask: UnsafePointer<sigset_t>? = nil
    ) throws -> Int {
        if Poll.pwait2Unavailable.load(ordering: .acquiring) {
            return try wait(on: poll, timeout: .milliseconds(timeout.rawMilliseconds))
        }
        while true {
            let sec: Int = Int(truncatingIfNeeded: timeout.rawNanoseconds.sec)
            let nsec: Int = Int(timeout.rawNanoseconds.nsec)
            let sigsetSize: UInt = UInt(MemoryLayout<sigset_t>.size)
            let n: CInt
            if let sigmask {
                n = sl_epoll_pwait2(
                    poll.epfd,
                    _rawBuffer,
                    CInt(capacity),
                    sec,
                    nsec,
                    UnsafeRawPointer(sigmask),
                    sigsetSize
                )
            } else {
                n = sl_epoll_pwait2(
                    poll.epfd,
                    _rawBuffer,
                    CInt(capacity),
                    sec,
                    nsec,
                    nil,
                    sigsetSize
                )
            }
            if n >= 0 {
                _setDeliveredCount(Int(n))
                return Int(n)
            }
            let err = -n
            if err == EINTR { continue }
            if err == ENOSYS {
                Poll.pwait2Unavailable.store(true, ordering: .releasing)
                return try wait(on: poll, timeout: .milliseconds(timeout.rawMilliseconds))
            }
            _setDeliveredCount(0)
            throw PollError(code: Int32(err), function: "epoll_pwait2")
        }
    }
}

#endif // os(Linux)
