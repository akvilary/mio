//===----------------------------------------------------------------------===//
//
//  TimerFd.swift
//  MIO
//
//  Monotonic periodic timer backed by timerfd(2). The reactor
//  (PollEventLoop) uses one instance to wake itself periodically so it
//  can sweep expired read/write deadlines — the mechanism that bounds
//  per-request read/write waits (Slowloris defence, write-stall defence).
//
//  Kept in mio (not pulsar) because timerfd is a low-level readiness/
//  timer source, symmetric with `Waker`. pulsar reaches it through the
//  `@_exported import MIO` re-export.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Foundation
import CMIO

#if canImport(Glibc)
import Glibc
#endif

/// A monotonic periodic timer backed by timerfd(2).
///
/// `create()` yields a non-blocking, close-on-exec fd; the caller
/// registers it with a `Poll` for `.readable` (level-triggered) and
/// drains it (an 8-byte `read`) each time the kernel reports it ready.
/// `setPeriodic(fd:interval:)` arms the first expiry one `interval`
/// after the call and repeats every `interval` thereafter.
public enum TimerFd {

    /// Create a `CLOCK_MONOTONIC` timerfd (`TFD_NONBLOCK | TFD_CLOEXEC`).
    /// Returns the fd, or `nil` on failure (e.g. `EMFILE`).
    public static func create() -> CInt? {
        let fd = sl_timerfd_create()
        return fd >= 0 ? fd : nil
    }

    /// Arm `fd` as a periodic timer whose first expiry is one `interval`
    /// after this call and which then repeats every `interval`. Pass
    /// `.zero` to disarm. Returns `true` on success.
    @discardableResult
    public static func setPeriodic(fd: CInt, interval: Duration) -> Bool {
        // Duration.components → (seconds: Int64, attoseconds: Int64).
        // timerfd wants a `timespec` (seconds + nanoseconds).
        let (sec, attosec) = interval.components
        let nsec = Int(attosec / 1_000_000_000)
        return sl_timerfd_settime(fd, Int(sec), nsec) == 0
    }
}

#endif // os(Linux)
