//===----------------------------------------------------------------------===//
//
//  Poll.swift / Registry.swift
//  MIO
//
//  Low-level mio analog. `Registry` is the ARC-shared owner of the epoll
//  fd; `Poll` is a lightweight value wrapping it. Mirrors
//  `mio::{Poll, Registry}` (rust) with ownership adapted to ARC: where
//  mio keeps its selector alive across `Registry::try_clone` via
//  `OwnedFd`/`dup(2)`, here reference counting does the same job with
//  no extra allocation or syscall.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import CMIO
import Synchronization

#if canImport(Glibc)
import Glibc
#endif

/// Timeout argument for `Poll.poll`. Maps cleanly onto the `int timeout`
/// argument of `epoll_wait(2)`:
///
///   - `.blocking`        → -1 (block indefinitely)
///   - `.immediate`       →  0 (non-blocking poll, return immediately)
///   - `.milliseconds(n)` →  n (block up to n ms)
@frozen
public struct PollTimeout: Sendable, Hashable {
    public let rawMilliseconds: CInt

    /// Nanosecond-resolution timeout for `Poll.pollNano`. Only consulted
    /// when the kernel supports `epoll_pwait2` (Linux 5.11+); ignored
    /// (with a fall-back to millisecond resolution) otherwise.
    public let rawNanoseconds: Nanoseconds

    /// `timespec`-style nanosecond timeout component.
    @frozen
    public struct Nanoseconds: Sendable, Hashable {
        /// Seconds. Negative means "block forever".
        public let sec: Int64
        /// Nanoseconds within the second. Range: `0 ..< 1_000_000_000`.
        public let nsec: Int32

        @inlinable public init(sec: Int64, nsec: Int32 = 0) {
            precondition(nsec >= 0 && nsec < 1_000_000_000, "nsec out of range")
            self.sec = sec
            self.nsec = nsec
        }
    }

    @inlinable
    internal init(raw: CInt) {
        self.rawMilliseconds = raw
        // Coarse conversion for the nano component — only consulted by
        // callers who override `rawNanoseconds` explicitly.
        if raw < 0 {
            self.rawNanoseconds = Nanoseconds(sec: -1, nsec: 0)
        } else {
            let ms = Int64(raw)
            self.rawNanoseconds = Nanoseconds(
                sec: ms / 1000,
                nsec: Int32((ms % 1000) * 1_000_000)
            )
        }
    }

    @inlinable
    internal init(milliseconds: CInt, nanoseconds: Nanoseconds) {
        self.rawMilliseconds = milliseconds
        self.rawNanoseconds = nanoseconds
    }

    public static let blocking   = PollTimeout(raw: -1)
    public static let immediate  = PollTimeout(raw: 0)

    public static func milliseconds(_ ms: Int) -> PollTimeout {
        // Clamp to epoll_wait's int range (~24.8 days) instead of
        // trapping on overflow; negative values collapse to 0
        // (immediate). Negative timeout values are reserved for "block
        // forever" and are only expressible via .blocking.
        let clamped = ms <= 0 ? 0 : min(ms, Int(CInt.max))
        return PollTimeout(raw: CInt(clamped))
    }

    public static func milliseconds(_ ms: CInt) -> PollTimeout {
        return milliseconds(Int(max(0, ms)))
    }

    /// Nanosecond-resolution timeout. Requires Linux 5.11+ for
    /// `epoll_pwait2`; on older kernels `Poll.pollNano` falls back to
    /// millisecond truncation (rounded up to avoid under-shooting).
    ///
    /// `sec` may be negative (block forever); `nsec` must be in `0 ..< 1_000_000_000`.
    /// Overflow never traps: the millisecond **fallback** saturates at
    /// `CInt.max` (~24.8 days — the widest timeout `epoll_wait` accepts),
    /// while the nanosecond component carries the caller's full value —
    /// on `epoll_pwait2` kernels (`timespec.tv_sec` is 64-bit) huge
    /// timeouts are honoured exactly.
    public static func nanoseconds(_ sec: Int64, _ nsec: Int32 = 0) -> PollTimeout {
        precondition(nsec >= 0 && nsec < 1_000_000_000, "nsec out of range")
        let ms: CInt
        if sec < 0 {
            ms = -1
        } else if sec > Int64(CInt.max) / 1_000 + 1 {
            // Beyond the ms range *and* beyond what sec*1e9 could hold
            // without overflowing Int64 — saturate rather than trap.
            ms = CInt.max
        } else {
            // Ceiling-divide into milliseconds for the fallback path so
            // the caller never waits less than requested when
            // epoll_pwait2 is unavailable. `sec` is bounded above, so
            // the product cannot overflow.
            let totalNs = sec * 1_000_000_000 + Int64(nsec)
            ms = CInt(min((totalNs + 999_999) / 1_000_000, Int64(CInt.max)))
        }
        return PollTimeout(
            milliseconds: ms,
            nanoseconds: Nanoseconds(sec: sec, nsec: nsec)
        )
    }
}

/// Top-level epoll handle.
///
/// A `Poll` wraps the ARC-shared `Registry` that owns the epoll fd
/// (created via `epoll_create1` with `EPOLL_CLOEXEC`). Sources are
/// registered through `registry`; events are awaited through `poll`.
///
/// Threading model: `Poll` and `Registry` are `Sendable`. `Registry`
/// may be shared freely and used from any thread. The same epoll fd may
/// be concurrently waited on via `poll` (from one thread) and modified
/// via `register`/`reregister`/`deregister` (from any thread) — this is
/// explicitly permitted by epoll(7). The realistic pattern is one
/// thread per `Poll`, with cross-thread registration as needed.
/// `Sendable` is satisfied structurally: `Poll`'s only stored property
/// is a `let` reference to the `Registry` class, which itself stores an
/// immutable fd and relies on kernel-side epoll synchronisation.
///
/// **Ownership (ARC adaptation of mio):** `Poll` is a value (struct);
/// the epoll fd lives as long as the **last** reference to `registry`.
/// Dropping the `Poll` value itself does not close the fd — any stored
/// `Registry` keeps the epoll instance alive, and when the final
/// reference is released, `Registry.deinit` closes the fd (the kernel
/// then drops all registrations atomically). There is no EBADF
/// lifetime contract to uphold. This mirrors mio's `OwnedFd` semantics
/// — Rust's mio achieves the same via `Registry::try_clone` + `dup(2)`;
/// ARC gives it to us for free, with one allocation instead of two.
public struct Poll: Sendable {

    /// The registry associated with this poll instance. Retaining it
    /// keeps the epoll fd alive.
    public let registry: Registry

    /// Raw epoll fd. Diagnostic accessor used by integration tests;
    /// production code should go through `Registry`.
    public var epfd: CInt { registry._epfd }

    /// Process-wide cache: `true` once `epoll_pwait2` has returned
    /// `ENOSYS` (kernel < 5.11) on any `Poll` instance. Subsequent
    /// `pollNano` calls bypass the syscall entirely and fall back to
    /// `epoll_wait`. The value can only transition false → true, so a
    /// racy read on first assignment at worst pays one extra failing
    /// syscall before the flag latches.
    internal static let pwait2Unavailable = Atomic<Bool>(false)

    public init() throws {
        self.registry = try Registry()
    }

    /// Wait for registered sources to become ready and write up to
    /// `events.capacity` events into `events`.
    ///
    /// On return, `events.count` reflects the number of delivered events
    /// (0 on timeout). Previous contents of `events` are overwritten.
    ///
    /// `EINTR` is retried automatically — callers never see it. All other
    /// errors are surfaced as `PollError`.
    ///
    /// **Blocking syscall.** `poll` calls `epoll_wait(2)` which may
    /// block indefinitely with `timeout: .blocking`. Do NOT call from
    /// Swift's cooperative thread pool — use a dedicated `Thread` or an
    /// actor with a custom `SerialExecutor` (see `PollEventLoop` in the
    /// `starlight` package for a reference implementation).
    ///
    /// This is the imperative form for callers who hold `Events` as a
    /// stack-local `var`. For `Events` stored as a class field (where
    /// `&self.events` is not expressible), prefer the OO form
    /// `events.wait(on: poll, timeout:)`.
    @discardableResult
    public func poll(
        _ events: inout Events,
        timeout: PollTimeout = .blocking
    ) throws -> Int {
        try events.wait(on: self, timeout: timeout)
    }

    /// Nanosecond-resolution variant of `poll`. Uses `epoll_pwait2`
    /// (Linux 5.11+); on older kernels (or any `ENOSYS` from the
    /// kernel), silently falls back to millisecond truncation via
    /// `epoll_wait`. `sigmask` may be `nil` for no signal-mask change.
    ///
    /// `EINTR` is retried automatically. Other errors are surfaced as
    /// `PollError`. The `ENOSYS` result is cached process-wide so the
    /// fallback path costs one extra branch per call, not one extra
    /// syscall.
    ///
    /// **Blocking syscall** — same cooperative-thread-pool caveat as
    /// `poll(_:timeout:)` applies. For class-stored `Events`, use
    /// `events.waitNano(on:timeout:sigmask:)` instead.
    @discardableResult
    public func pollNano(
        _ events: inout Events,
        timeout: PollTimeout,
        sigmask: UnsafePointer<sigset_t>? = nil
    ) throws -> Int {
        try events.waitNano(on: self, timeout: timeout, sigmask: sigmask)
    }
}

/// The ARC-shared owner of an epoll fd, exposing only the source
/// registration surface.
///
/// `Registry` is a reference type on purpose: sharing it across threads
/// (storing it in event loops, connection drivers, worker contexts) is
/// how the epoll fd's lifetime is extended — ARC plays the role mio
/// gives to `OwnedFd` + `dup(2)`. The fd is closed in `deinit`, i.e.
/// when the last reference is released.
///
/// It is `Equatable`/`Hashable` by **identity** (same object), never by
/// the raw fd number: once an fd is closed the kernel may recycle its
/// number for an unrelated file, so fd-number equality would
/// misidentify distinct registries. Two registries are equal iff they
/// reference the same epoll instance — obtainable only via
/// `poll.registry` from the same `Poll`.
public final class Registry: Sendable, Hashable {
    @usableFromInline internal let _epfd: CInt

    #if DEBUG
    /// Debug-only diagnostic mirroring mio's `Registry::register_waker`:
    /// at most one Waker per registry. Multiple wakers sharing a token
    /// defeat the loop's drain logic — an un-drained level-triggered
    /// eventfd keeps the token readable on every poll (busy-loop), and
    /// with the conventional `Token.wakeup` collisions are easy to hit.
    /// Multiplex wake reasons behind a single waker instead: set
    /// flags/enqueue into a queue, `wake()`, let the loop check them
    /// after wakeup — the canonical tokio pattern.
    ///
    /// Like mio, the flag never clears: creating a second waker after
    /// the first one died still traps. Wakers are loop-lifetime objects.
    private let _hasWaker = Atomic<Bool>(false)
    #endif

    /// Creates the epoll fd (`epoll_create1` + `EPOLL_CLOEXEC`).
    /// Internal: obtain a `Registry` from `Poll.registry`, mirroring
    /// mio where `Registry` is only handed out by `Poll`.
    internal init() throws {
        let fd = sl_epoll_create1()
        // sl_epoll_create1 returns either a non-negative fd on success
        // or `-errno` on failure — race-free errno capture at the C
        // layer (the C function captures errno before any subsequent
        // syscall can clobber it).
        guard fd >= 0 else {
            throw PollError(code: Int32(-fd), function: "epoll_create1")
        }
        self._epfd = fd
    }

    #if DEBUG
    /// Debug-only single-waker enforcement (mio parity). Called from
    /// `Waker.init` after a successful registration.
    internal func _registerWaker() {
        assert(
            !_hasWaker.exchange(true, ordering: .acquiringAndReleasing),
            "Only a single Waker can be active per Registry (mio parity). " +
            "Multiplex wake reasons behind one waker: flags/queue checked " +
            "after wakeup, as tokio does."
        )
    }
    #endif

    deinit {
        // The single owner: runs when the last reference (from `Poll`,
        // a stored `Registry`, etc.) is released. Closing the epoll fd
        // atomically removes every registration kernel-side.
        _ = Glibc.close(_epfd)
    }

    /// Register `fd` for notifications described by `interest`, tagging
    /// it with `token`. The token is returned verbatim in any subsequent
    /// `Event`.
    ///
    /// The fd must not already be registered with this epoll instance
    /// (`EEXIST` is raised as `PollError`). The fd must be a valid kernel
    /// file descriptor — `epoll_ctl(2)` rejects fds referring to a
    /// different epoll instance, but accepts any non-epoll fd.
    ///
    /// Mirroring mio's `interests_to_epoll`, `EPOLLRDHUP` is added
    /// automatically to `.readable` registrations so peer half-close is
    /// observable in delivered events (`Event.isReadClosed`).
    public func register(
        fd: CInt, token: Token, interest: Interest
    ) throws {
        // Reject an unsupported flag combination up-front. The kernel
        // would also reject this (EINVAL) but the error message would
        // be opaque; the assertion fires only in debug builds so there
        // is no release-cost.
        assert(!(interest.isExclusive && interest.isEdge),
            "EPOLLEXCLUSIVE may not be combined with EPOLLET (kernel ABI)")
        let rc = sl_epoll_ctl_add(_epfd, fd, interest._epollBits, token.raw)
        if rc != 0 {
            throw PollError(code: Int32(-rc), function: "epoll_ctl(ADD)")
        }
    }

    /// Re-register `fd` with a new `token`/`interest`. Used to re-arm
    /// oneshot sources after an event, or to change interest bits on a
    /// live registration.
    public func reregister(
        fd: CInt, token: Token, interest: Interest
    ) throws {
        let rc = sl_epoll_ctl_mod(_epfd, fd, interest._epollBits, token.raw)
        if rc != 0 {
            throw PollError(code: Int32(-rc), function: "epoll_ctl(MOD)")
        }
    }

    /// Remove `fd` from this epoll instance. Idempotent at the kernel
    /// level only if the fd is registered; calling `deregister` on a
    /// never-registered fd returns `ENOENT`, surfaced as `PollError`.
    public func deregister(fd: CInt) throws {
        let rc = sl_epoll_ctl_del(_epfd, fd)
        if rc != 0 {
            throw PollError(code: Int32(-rc), function: "epoll_ctl(DEL)")
        }
    }

    /// Best-effort deregister. Returns `true` if the fd was successfully
    /// removed, `false` if the kernel reported `ENOENT` (the fd was not
    /// registered). Any other error (e.g. `EBADF`) is still surfaced via
    /// `throw`. Useful in cleanup/deinit paths where the fd may already
    /// have been removed or recycled.
    ///
    /// Note: for fds you own and are about to `close(2)`, an explicit
    /// deregister is redundant — closing an fd removes it from every
    /// epoll interest list atomically.
    @discardableResult
    public func tryDeregister(fd: CInt) throws -> Bool {
        let rc = sl_epoll_ctl_del(_epfd, fd)
        if rc == 0 { return true }
        let err = Int32(-rc)
        if err == ENOENT { return false }
        throw PollError(code: err, function: "epoll_ctl(DEL)")
    }

    // ── Hashable / Equatable — by object identity ─────────────────────

    public static func == (lhs: Registry, rhs: Registry) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

#endif // os(Linux)
