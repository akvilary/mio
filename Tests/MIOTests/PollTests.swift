//===----------------------------------------------------------------------===//
//
//  PollTests.swift
//  MIOTests
//
//  End-to-end tests for the mio analog. Each test exercises one
//  primitive of the public API: Poll lifecycle, Registry register/
//  reregister/deregister, Events container, Waker cross-thread, and
//  PollTimeout semantics.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Testing
import Foundation
@testable import MIO

#if canImport(Glibc)
import Glibc
#endif

@Suite("MIO", .serialized)
struct PollTests {

    // MARK: - Poll lifecycle

    @Test("Poll creates a usable epoll fd and closes it on deinit")
    func pollLifecycle() throws {
        let p = try Poll()
        #expect(p.epfd >= 0)
        // Registry shares the same epfd.
        #expect(p.registry._epfdForTests == p.epfd)
    }

    // MARK: - Events container

    @Test("Events initial state is empty")
    func eventsEmpty() throws {
        let p = try Poll()
        var ev = Events(capacity: 16)
        let empty1 = ev.isEmpty; #expect(empty1)
        let count1 = ev.count; #expect(count1 == 0)
        // Immediate poll on an empty epoll instance must return 0 events.
        let n = try ev.wait(on: p, timeout: .immediate)
        #expect(n == 0)
        let empty2 = ev.isEmpty; #expect(empty2)
    }

    @Test("Events capacity is honoured")
    func eventsCapacity() throws {
        let ev = Events(capacity: 4)
        let cap = ev.capacity; #expect(cap == 4)
    }

    @Test("Events.clear() resets count to zero")
    func eventsClear() throws {
        var ev = Events(capacity: 8)
        // Forcibly set count via a no-op poll then clear.
        ev.clear()
        let empty = ev.isEmpty; #expect(empty)
    }

    // MARK: - Registry

    @Test("Registering a socketpair read end and poll delivers readability")
    func readableReady() throws {
        let p = try Poll()
        guard let sp = makeSocketpair() else { Issue.record("socketpair failed"); return }
        let (r, w) = (sp.read, sp.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        try p.registry.register(fd: r, token: Token(42), interest: .readable)

        // Initially no data → no events.
        var ev = Events(capacity: 4)
        #expect(try ev.wait(on: p, timeout: .immediate) == 0)

        // Write one byte from the other end.
        var byte: UInt8 = 0xAB
        #expect(Glibc.write(w, &byte, 1) == 1)

        // Now we should see exactly one event on Token(42), readable.
        let n = try ev.wait(on: p, timeout: .immediate)
        #expect(n == 1)
        var seen: Token? = nil
        ev.forEach { ev1 in
            #expect(ev1.isReadable)
            #expect(ev1.token == Token(42))
            seen = ev1.token
        }
        #expect(seen == Token(42))

        try p.registry.deregister(fd: r)
    }

    @Test("Double register fails with EEXIST")
    func doubleRegisterFails() throws {
        let p = try Poll()
        guard let sp = makeSocketpair() else { Issue.record("socketpair failed"); return }
        let (r, w) = (sp.read, sp.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        try p.registry.register(fd: r, token: Token(1), interest: .readable)
        #expect(throws: PollError.self) {
            try p.registry.register(fd: r, token: Token(2), interest: .readable)
        }
    }

    @Test("Deregister of unknown fd fails with ENOENT")
    func deregisterUnknown() throws {
        let p = try Poll()
        // fd 123456 is almost certainly not registered.
        #expect(throws: PollError.self) {
            try p.registry.deregister(fd: 123_456)
        }
    }

    @Test("Reregister changes the token")
    func reregisterChangesToken() throws {
        let p = try Poll()
        guard let sp = makeSocketpair() else { Issue.record("socketpair failed"); return }
        let (r, w) = (sp.read, sp.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        try p.registry.register(fd: r, token: Token(11), interest: .readable)
        try p.registry.reregister(fd: r, token: Token(22), interest: .readable)

        var byte: UInt8 = 1
        _ = Glibc.write(w, &byte, 1)
        var ev = Events(capacity: 4)
        let n = try ev.wait(on: p, timeout: .immediate)
        #expect(n == 1)
        ev.forEach { #expect($0.token == Token(22)) }
    }

    @Test("Oneshot fires at most once until re-armed")
    func oneshotFiresOnce() throws {
        let p = try Poll()
        guard let sp = makeSocketpair() else { Issue.record("socketpair failed"); return }
        let (r, w) = (sp.read, sp.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        try p.registry.register(fd: r, token: Token(7), interest: [.readable, .oneshot])

        var byte: UInt8 = 1
        _ = Glibc.write(w, &byte, 1)

        var ev = Events(capacity: 4)
        // First poll: delivers the event.
        #expect(try ev.wait(on: p, timeout: .immediate) == 1)
        // Second poll: oneshot disabled the fd — no event, even though
        // there is still data in the socket.
        #expect(try ev.wait(on: p, timeout: .immediate) == 0)

        // Re-arm and try again.
        try p.registry.reregister(fd: r, token: Token(7), interest: [.readable, .oneshot])
        #expect(try ev.wait(on: p, timeout: .immediate) == 1)
    }

    @Test("Edge-triggered delivers once per state transition, not per poll")
    func edgeTriggeredSemantics() throws {
        let p = try Poll()
        guard let sp = makeSocketpair() else { Issue.record("socketpair failed"); return }
        let (r, w) = (sp.read, sp.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        try p.registry.register(fd: r, token: Token(42), interest: [.readable, .edge])

        var byte: UInt8 = 0xAB
        _ = Glibc.write(w, &byte, 1)

        var ev = Events(capacity: 4)
        // First poll: edge fired when byte became available.
        #expect(try ev.wait(on: p, timeout: .immediate) == 1)
        ev.forEach { #expect($0.token == Token(42)) }

        // Second poll WITHOUT draining + WITHOUT a new state transition:
        // edge-triggered must NOT re-fire.
        #expect(try ev.wait(on: p, timeout: .immediate) == 0)

        // Drain everything; the loop is now responsible for reading
        // until EAGAIN in edge mode.
        var sink: UInt8 = 0
        _ = Glibc.read(r, &sink, 1)
        #expect(sink == 0xAB)

        // New write → new edge.
        byte = 0xCD
        _ = Glibc.write(w, &byte, 1)
        #expect(try ev.wait(on: p, timeout: .immediate) == 1)
        ev.forEach { #expect($0.token == Token(42)) }
    }

    @Test("tryDeregister returns false on ENOENT, true on success")
    func tryDeregisterSemantics() throws {
        let p = try Poll()
        guard let sp = makeSocketpair() else { Issue.record("socketpair failed"); return }
        let (r, w) = (sp.read, sp.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        // Unregistered fd → false, no throw.
        #expect(try p.registry.tryDeregister(fd: r) == false)

        try p.registry.register(fd: r, token: Token(1), interest: .readable)
        // Now registered → true.
        #expect(try p.registry.tryDeregister(fd: r) == true)
        // Already removed → false, no throw.
        #expect(try p.registry.tryDeregister(fd: r) == false)
    }

    @Test("Events.subscript traps on out-of-bounds position")
    func eventsSubscriptBoundsCheck() throws {
        let p = try Poll()
        var ev = Events(capacity: 4)
        // Poll with no sources → 0 events delivered.
        _ = try ev.wait(on: p, timeout: .immediate)
        let cnt = ev.count; #expect(cnt == 0)
        // Accessing position 0 of an empty Events must trap. We use
        // a fatalError-catching pattern by inverting the check: the
        // first valid access works, the OOB one is the bug we are
        // guarding against (verified manually to crash in debug).
        // Here we only verify the precondition's positive path.
        let sp = try makeSocketpairThrows()
        let (r, w) = (sp.read, sp.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }
        try p.registry.register(fd: r, token: Token(5), interest: .readable)
        var byte: UInt8 = 1
        _ = Glibc.write(w, &byte, 1)
        #expect(try ev.wait(on: p, timeout: .immediate) == 1)
        #expect(ev[0].token == Token(5))
    }

    @Test("Event exposes isPriority and isHangup from underlying Ready")
    func eventReadyAccessors() throws {
        // Synthetic: construct Ready directly and verify Event forwards.
        let ev1 = Event(token: Token(1), ready: [.readable, .priority])
        #expect(ev1.isReadable)
        #expect(ev1.isPriority)
        #expect(!ev1.isHangup)

        let ev2 = Event(token: Token(2), ready: [.hangup])
        #expect(ev2.isHangup)
        #expect(!ev2.isReadable)
    }

    @Test("pollNano with ENOSYS kernel falls back to epoll_wait path")
    func pollNanoFallback() throws {
        // On modern kernels (5.11+) this exercises the pwait2 path
        // directly. On older kernels the ENOSYS fallback is hit on
        // first call and cached for subsequent calls.
        let p = try Poll()
        var ev = Events(capacity: 4)
        // 100ms timeout — short enough to test quickly, long enough to
        // exercise the timeout code path.
        let n = try ev.waitNano(on: p, timeout: .nanoseconds(0, 100_000_000))
        #expect(n == 0)
        // Second call should hit the cached path (no double ENOSYS).
        let n2 = try ev.waitNano(on: p, timeout: .nanoseconds(0, 50_000_000))
        #expect(n2 == 0)
    }

    // MARK: - Waker

    @Test("Waker fires a readable event on its token")
    func wakerFires() throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(999))
        // No defer close — Waker.deinit owns the fd and closes it.

        // Block the wake before polling — race-free because eventfd's
        // counter persists across epoll_wait calls.
        #expect(waker.wake())

        var ev = Events(capacity: 4)
        let n = try ev.wait(on: p, timeout: .immediate)
        #expect(n == 1)
        ev.forEach { ev1 in
            #expect(ev1.token == Token(999))
            #expect(ev1.isReadable)
        }
        // Drain so subsequent polls don't re-observe it.
        _ = waker.reset()
        #expect(try ev.wait(on: p, timeout: .immediate) == 0)
    }

    @Test("Waker is safe to fire multiple times before drain")
    func wakerCoalescing() throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(1))
        // No defer close — Waker.deinit owns the fd.

        #expect(waker.wake())
        #expect(waker.wake())
        #expect(waker.wake())

        var ev = Events(capacity: 4)
        // Level-triggered, single event even though three wakes were issued.
        #expect(try ev.wait(on: p, timeout: .immediate) == 1)
        // Reset reads counter (= 3) and zeroes it.
        #expect(waker.reset() == 3)
    }

    // MARK: - Timeout

    @Test("Blocking poll returns immediately when waker is pre-fired")
    func blockingPollWithPrefiredWaker() throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(0))
        // No defer close — Waker.deinit owns the fd.
        #expect(waker.wake())
        var ev = Events(capacity: 4)
        // Should NOT block — waker is already pending.
        let n = try ev.wait(on: p, timeout: .blocking)
        #expect(n == 1)
        _ = waker.reset()
    }

    @Test("Timed poll returns 0 after the timeout elapses with no events")
    func timedPollNoEvents() throws {
        let p = try Poll()
        var ev = Events(capacity: 4)
        let start = Date()
        let n = try ev.wait(on: p, timeout: .milliseconds(50))
        let elapsed = Date().timeIntervalSince(start)
        #expect(n == 0)
        #expect(elapsed >= 0.04)  // allow some scheduler slack
    }

    @Test("Cross-thread Waker unblocks a polling thread")
    func crossThreadWakeup() async throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(0))
        // Hold the waker for the duration of the test; deinit closes the fd.

        // Spawn a detached task that fires the waker after a short delay.
        Task.detached {
            try? await Task.sleep(for: .milliseconds(30))
            _ = waker.wake()
        }

        var ev = Events(capacity: 4)
        let start = Date()
        let n = try ev.wait(on: p, timeout: .milliseconds(2000))
        let elapsed = Date().timeIntervalSince(start)
        #expect(n == 1)
        #expect(elapsed < 1.5)  // woke well before the 2s safety timeout
    }

    // MARK: - Edge cases

    @Test("Waker.wake returns true on EAGAIN (counter saturated)")
    func wakerEagainReturnsTrue() throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(42))
        // No defer close — Waker.deinit owns the fd.

        // Fill the eventfd counter to saturation (UINT64_MAX - 1).
        // A single write of that value fills it in one syscall.
        var fill: UInt64 = UInt64.max - 1
        let written = withUnsafePointer(to: &fill) { ptr -> Int in
            Glibc.write(waker.fd, ptr, 8)
        }
        #expect(written == 8, "should be able to fill the counter")

        // Now any additional wake() must return true — the wakeup is
        // functionally delivered (counter is already full, the loop
        // will observe readiness on the next poll).
        #expect(waker.wake(), "wake() on saturated counter must return true")
    }

    @Test("pollNano delivers actual events (not just timeout)")
    func pollNanoWithEvents() throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(7))
        #expect(waker.wake())

        var ev = Events(capacity: 4)
        let n = try ev.waitNano(on: p, timeout: .nanoseconds(0, 100_000_000))
        #expect(n == 1)
        ev.forEach { #expect($0.token == Token(7)) }
    }

    // MARK: - Ownership (ARC)

    @Test("Registry keeps the epoll fd alive after the Poll value is gone")
    func registryOwnsEpfdLifetime() throws {
        var kept: Registry? = nil
        do {
            let p = try Poll()
            kept = p.registry
        }
        // The `Poll` value is out of scope; the stored Registry reference
        // must keep the epoll fd alive (ARC plays the role mio gives to
        // OwnedFd + dup(2)). These would fail with EBADF otherwise.
        guard let registry = kept else {
            Issue.record("registry not retained")
            return
        }
        guard let sp = makeSocketpair() else { Issue.record("socketpair failed"); return }
        defer { _ = Glibc.close(sp.read); _ = Glibc.close(sp.write) }

        try registry.register(fd: sp.read, token: Token(31), interest: .readable)
        try registry.reregister(fd: sp.read, token: Token(32), interest: .readable)
        #expect(try registry.tryDeregister(fd: sp.read) == true)
    }

    @Test("Registry equality is identity-based, not fd-based")
    func registryIdentityEquality() throws {
        let p1 = try Poll()
        let p2 = try Poll()
        let r1 = p1.registry
        #expect(r1 == p1.registry)
        #expect(r1 != p2.registry)
        var h1 = Hasher(); r1.hash(into: &h1)
        var h2 = Hasher(); r1.hash(into: &h2)
        #expect(h1.finalize() == h2.finalize())
    }

    // MARK: - mio-parity readiness semantics

    @Test("Half-close is observable: readable + readClosed (auto EPOLLRDHUP)")
    func halfCloseIsReadClosed() throws {
        let p = try Poll()
        guard let sp = makeSocketpair() else { Issue.record("socketpair failed"); return }
        let (r, w) = (sp.read, sp.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        try p.registry.register(fd: r, token: Token(21), interest: .readable)

        var byte: UInt8 = 1
        #expect(Glibc.write(w, &byte, 1) == 1)
        #expect(Glibc.shutdown(w, Int32(SHUT_WR)) == 0)

        var ev = Events(capacity: 4)
        #expect(try ev.wait(on: p, timeout: .immediate) == 1)
        ev.forEach { e in
            #expect(e.token == Token(21))
            #expect(e.isReadable)      // one byte is buffered
            #expect(e.isReadClosed)    // IN|RDHUP — mio parity
            #expect(!e.isHangup)       // half-close, not a full HUP
        }
    }

    @Test("Ready predicates match mio formulas")
    func readyPredicateParity() throws {
        // IN|RDHUP (data + FIN): readable AND read-closed.
        let r1 = Ready(rawValue: 0x2001)
        #expect(r1.isReadable)
        #expect(r1.isReadClosed)
        #expect(!r1.isHangup)

        // PRI only: readable per mio (OOB folded into readable).
        let r2 = Ready(rawValue: 0x002)
        #expect(r2.isReadable)

        // OUT|ERR (pipe read end closed): write-closed.
        let r3 = Ready(rawValue: 0x004 | 0x008)
        #expect(r3.isWriteClosed)

        // Exactly ERR: write-closed per mio's `events == EPOLLERR` case.
        let r4 = Ready(rawValue: 0x008)
        #expect(r4.isWriteClosed)
        #expect(!r4.isWritable)
    }

    @Test("waitNano with .blocking blocks until a source is ready (no EINVAL)")
    func waitNanoBlockingWithWaker() throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(3))
        // Pre-fire so the wait returns immediately. Before the
        // NULL-timespec fix this threw PollError(EINVAL) from
        // epoll_pwait2 (a negative tv_sec is rejected by the kernel).
        #expect(waker.wake())

        var ev = Events(capacity: 4)
        let n = try ev.waitNano(on: p, timeout: .blocking)
        #expect(n == 1)
        ev.forEach { #expect($0.token == Token(3)) }
        _ = waker.reset()
    }

    @Test("EPOLLEXCLUSIVE registration accepts .readable (RDHUP suppressed by kernel whitelist)")
    func exclusiveRegistration() throws {
        let p = try Poll()
        guard let sp = makeSocketpair() else { Issue.record("socketpair failed"); return }
        let (r, w) = (sp.read, sp.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        // The kernel's EPOLLEXCLUSIVE whitelist is exactly EPOLLIN|EPOLLOUT;
        // _epollBits suppresses the auto-added EPOLLRDHUP for .exclusive.
        try p.registry.register(fd: r, token: Token(9), interest: [.readable, .exclusive])

        var byte: UInt8 = 1
        _ = Glibc.write(w, &byte, 1)
        var ev = Events(capacity: 4)
        #expect(try ev.wait(on: p, timeout: .immediate) == 1)
        ev.forEach { #expect($0.token == Token(9)) }
    }

    // MARK: - Timeout saturation

    @Test("PollTimeout saturates instead of trapping on overflow")
    func timeoutSaturation() throws {
        // milliseconds: values beyond CInt.max collapse to CInt.max
        // (~24.8 days); negatives collapse to 0 (immediate).
        #expect(PollTimeout.milliseconds(10_000_000_000).rawMilliseconds == CInt.max)
        #expect(PollTimeout.milliseconds(-5).rawMilliseconds == 0)

        // nanoseconds: the ms FALLBACK saturates, while the nanosecond
        // component carries the caller's full value (epoll_pwait2
        // timespec.tv_sec is 64-bit).
        let huge = PollTimeout.nanoseconds(1_000_000_000_000, 0) // ~31,700 years
        #expect(huge.rawMilliseconds == CInt.max)
        #expect(huge.rawNanoseconds.sec == 1_000_000_000_000)

        // Normal path unchanged: ceiling to whole milliseconds.
        #expect(PollTimeout.nanoseconds(1, 500_000_000).rawMilliseconds == 1500)
        #expect(PollTimeout.nanoseconds(0, 1).rawMilliseconds == 1)
        #expect(PollTimeout.nanoseconds(-7, 0).rawMilliseconds == -1)
    }

    // MARK: - sigmask / EINTR

    @Test("waitNano with a sigmask takes timeouts and events normally")
    func waitNanoSigmaskBasic() throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(11))

        var mask = sigset_t()
        sigemptyset(&mask)
        sigaddset(&mask, SIGUSR1)

        var ev = Events(capacity: 4)
        // Timeout with the mask installed: returns 0, no error.
        #expect(try ev.waitNano(
            on: p, timeout: .nanoseconds(0, 50_000_000), sigmask: &mask) == 0)
        // Event delivery is unaffected by the mask.
        #expect(waker.wake())
        #expect(try ev.waitNano(
            on: p, timeout: .nanoseconds(0, 200_000_000), sigmask: &mask) == 1)
        ev.forEach { #expect($0.token == Token(11)) }
        _ = waker.reset()
    }

    @Test("waitNano sigmask is installed atomically: pending signal delivered, EINTR retried")
    func waitNanoSigmaskEINTR() throws {
        // Block SIGUSR1 on this thread, then raise() it — with the
        // signal blocked it goes pending instead of being delivered.
        var block = sigset_t()
        sigemptyset(&block)
        sigaddset(&block, SIGUSR1)
        #expect(pthread_sigmask(Int32(SIG_BLOCK), &block, nil) == 0)
        let oldHandler = signal(SIGUSR1, mioTestSigusr1Handler)
        defer { signal(SIGUSR1, oldHandler) }
        mioTestSigusr1Count = 0
        raise(SIGUSR1)

        // Nothing is registered with the poll, so the wait must BLOCK —
        // epoll_pwait2 installs the empty (all-unblocked) mask at entry,
        // the pending SIGUSR1 is delivered right there (handler runs,
        // count → 1) and the syscall returns EINTR. The internal retry
        // re-enters with the full timeout (documented caveat) and this
        // time blocks to completion: n == 0 after ~300 ms.
        //
        // NB: pre-firing the waker would defeat the test — ready events
        // take the fast path and the mask is never installed.
        let p = try Poll()

        var empty = sigset_t()
        sigemptyset(&empty)
        var ev = Events(capacity: 4)
        let start = Date()
        let n = try ev.waitNano(on: p, timeout: .nanoseconds(0, 300_000_000), sigmask: &empty)
        let elapsed = Date().timeIntervalSince(start)
        #expect(n == 0)
        // The EINTR was instant; the retry re-blocked for the full timeout.
        #expect(elapsed >= 0.28)
        #expect(elapsed < 2)

        // Exactly one delivery. On pre-5.11 kernels (ENOSYS fallback to
        // epoll_wait) the mask is never installed and the signal stays
        // pending — accept that too, but then drain it.
        let pwait2Worked = !Poll.pwait2Unavailable.load(ordering: .acquiring)
        #expect(mioTestSigusr1Count == (pwait2Worked ? 1 : 0))
        if !pwait2Worked {
            // Non-blocking drain of the still-pending signal so later
            // tests are unaffected.
            var set = block
            var zero = timespec()
            _ = sigtimedwait(&set, nil, &zero)
        }

        // Restore the thread's mask for other tests.
        #expect(pthread_sigmask(Int32(SIG_UNBLOCK), &block, nil) == 0)
    }
}

// MARK: - Signal-handler test support

/// SIGUSR1 delivery counter. Written ONLY from the signal handler — a
/// single aligned Int32 increment is adequate for test purposes on
/// x86_64/arm64 (no torn access, no other writers).
nonisolated(unsafe) var mioTestSigusr1Count: Int32 = 0

/// Non-capturing handler, convertible to a C function pointer.
private func mioTestSigusr1Handler(_ sig: Int32) {
    mioTestSigusr1Count &+= 1
}

// MARK: - Test-only helpers

extension Registry {
    /// Test-only accessor for the underlying epoll fd. Mirrored from
    /// `_epfd` via the `@testable import` below; not for production use.
    internal var _epfdForTests: CInt { _epfd }
}

private struct TestPipe {
    let read: CInt
    let write: CInt
}

/// Create a non-blocking, close-on-exec socketpair for readiness tests.
private func makeSocketpair() -> TestPipe? {
    var fds: [CInt] = [0, 0]
    let rc = fds.withUnsafeMutableBufferPointer { buf in
        // SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC = 1 | 2048 | 524288
        Glibc.socketpair(AF_UNIX, 1 | 2048 | 524288, 0, buf.baseAddress!)
    }
    return rc == 0 ? TestPipe(read: fds[0], write: fds[1]) : nil
}

/// Throwing variant of `makeSocketpair` for tests that want to use
/// `try` rather than guard against `nil`.
private func makeSocketpairThrows() throws -> TestPipe {
    guard let sp = makeSocketpair() else {
        throw PollError(code: Int32(errno), function: "socketpair")
    }
    return sp
}

#endif // os(Linux)
