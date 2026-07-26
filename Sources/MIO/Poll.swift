//===----------------------------------------------------------------------===//
//
//  Poll.swift / Registry.swift
//  MIO
//
//  Low-level mio analog. `Poll` owns the epoll fd; `Registry` is a
//  shareable handle exposing only the registration surface. Mirrors
//  `mio::{Poll, Registry}` (rust).
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Foundation
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
        // Clamp to epoll_wait's int range. Negative values are reserved
        // for "block forever" — anything < -1 is undefined behaviour.
        let clamped = max(0, CInt(ms))
        return PollTimeout(raw: clamped)
    }

    public static func milliseconds(_ ms: CInt) -> PollTimeout {
        return milliseconds(Int(max(0, ms)))
    }

    /// Nanosecond-resolution timeout. Requires Linux 5.11+ for
    /// `epoll_pwait2`; on older kernels `Poll.pollNano` falls back to
    /// millisecond truncation (rounded up to avoid under-shooting).
    ///
    /// `sec` may be negative (block forever); `nsec` must be in `0 ..< 1_000_000_000`.
    public static func nanoseconds(_ sec: Int64, _ nsec: Int32 = 0) -> PollTimeout {
        precondition(nsec >= 0 && nsec < 1_000_000_000, "nsec out of range")
        // Ceiling-divide into milliseconds for the fallback path so the
        // caller never waits less than requested when epoll_pwait2 is
        // unavailable. Swift traps on Int64 overflow, so an absurd
        // timeout (>292 years) crashes rather than silently wrapping.
        let totalNs: Int64 = sec >= 0
            ? sec * 1_000_000_000 + Int64(nsec)
            : -1
        let ms: CInt = totalNs < 0
            ? -1
            : CInt((totalNs + 999_999) / 1_000_000)
        return PollTimeout(
            milliseconds: ms,
            nanoseconds: Nanoseconds(sec: sec, nsec: nsec)
        )
    }
}

/// Top-level epoll handle.
///
/// A `Poll` owns a single epoll fd (created via `epoll_create1` with
/// `EPOLL_CLOEXEC`). Sources are registered through `registry`; events
/// are awaited through `poll`.
///
/// Threading model: the `Poll`/`Registry` pair is `Sendable`. `Registry`
/// may be cloned freely and used from any thread. The same epoll fd may
/// be concurrently read via `poll` (from one thread) and modified via
/// `register`/`reregister`/`deregister` (from any thread) — this is
/// explicitly permitted by epoll(7). The realistic pattern is one
/// thread per `Poll`, with cross-thread registration as needed.
///
/// `Sendable` is satisfied structurally: both stored properties are
/// immutable (`let`) and themselves `Sendable`. The class performs no
/// shared mutable state of its own — `epoll_ctl` and `epoll_wait` are
/// thread-safe in the kernel.
///
/// **Lifetime contract:** `Poll` owns the epoll fd and closes it in
/// `deinit`. `Registry` is a lightweight handle that does NOT keep
/// `Poll` alive — it stores only the raw fd integer. The caller MUST
/// keep `Poll` alive as long as any `Registry` or `Waker` is in use;
/// otherwise `epoll_ctl`/`epoll_wait` calls on the closed fd will
/// return `EBADF`. In Rust's mio this is enforced by the borrow checker
/// (`Registry` borrows `Poll`); in Swift it is a runtime contract.
public final class Poll: Sendable {

    /// Raw epoll fd. Used by integration tests; production code should
    /// go through `Registry`.
    public let epfd: CInt

    /// The registry associated with this poll instance.
    public let registry: Registry

    /// Process-wide cache: `true` once `epoll_pwait2` has returned
    /// `ENOSYS` (kernel < 5.11) on any `Poll` instance. Subsequent
    /// `pollNano` calls bypass the syscall entirely and fall back to
    /// `epoll_wait`. The value can only transition false → true, so a
    /// racy read on first assignment at worst pays one extra failing
    /// syscall before the flag latches.
    internal static let pwait2Unavailable = Atomic<Bool>(false)

    public init() throws {
        let fd = sl_epoll_create1()
        // sl_epoll_create1 returns either a non-negative fd on success
        // or `-errno` on failure — race-free errno capture at the C
        // layer (the C function captures errno before any subsequent
        // syscall can clobber it).
        guard fd >= 0 else {
            throw PollError(code: Int32(-fd), function: "epoll_create1")
        }
        self.epfd = fd
        self.registry = Registry(epfd: fd)
    }

    deinit {
        // `epfd` is a `let` assigned only after a successful `init`;
        // any throwing init path leaves no `Poll` instance to deinit.
        // The guard is therefore unreachable in correct usage but kept
        // defensive against future reinit paths.
        if epfd >= 0 { _ = Glibc.close(epfd) }
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

/// A handle to a `Poll` exposing only source registration.
///
/// `Registry` is `Equatable` (two registries are equal iff they reference
/// the same underlying epoll fd) and `Hashable`. It may be shared across
/// threads. `Sendable` is structural: the only stored property is an
/// immutable fd, and `epoll_ctl(2)` is thread-safe.
public final class Registry: Sendable, Hashable {
    @usableFromInline internal let _epfd: CInt

    @usableFromInline internal init(epfd: CInt) {
        self._epfd = epfd
    }

    /// Register `fd` for notifications described by `interest`, tagging
    /// it with `token`. The token is returned verbatim in any subsequent
    /// `Event`.
    ///
    /// The fd must not already be registered with this epoll instance
    /// (`EEXIST` is raised as `PollError`). The fd must be a valid kernel
    /// file descriptor — `epoll_ctl(2)` rejects fds referring to a
    /// different epoll instance, but accepts any non-epoll fd.
    public func register(
        fd: CInt, token: Token, interest: Interest
    ) throws {
        // Reject an unsupported flag combination up-front. The kernel
        // would also reject this (EINVAL) but the error message would
        // be opaque; the assertion fires only in debug builds so there
        // is no release-cost.
        assert(!(interest.isExclusive && interest.isEdge),
            "EPOLLEXCLUSIVE may not be combined with EPOLLET (kernel ABI)")
        let rc = sl_epoll_ctl_add(_epfd, fd, interest.rawValue, token.raw)
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
        let rc = sl_epoll_ctl_mod(_epfd, fd, interest.rawValue, token.raw)
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
    @discardableResult
    public func tryDeregister(fd: CInt) throws -> Bool {
        let rc = sl_epoll_ctl_del(_epfd, fd)
        if rc == 0 { return true }
        let err = Int32(-rc)
        if err == ENOENT { return false }
        throw PollError(code: err, function: "epoll_ctl(DEL)")
    }

    // ── Hashable / Equatable — by underlying epfd ──────────────────────

    public static func == (lhs: Registry, rhs: Registry) -> Bool {
        lhs._epfd == rhs._epfd
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(_epfd)
    }
}

#endif // os(Linux)
