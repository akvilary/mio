# MIO

A Swift port of [**mio** (Rust)](https://github.com/tokio-rs/mio): lightweight,
portable, readiness-based I/O primitives backed by `epoll` on Linux. The public
surface mirrors mio's — `Poll`, `Registry`, `Token`, `Interest`, `Ready`,
`Event`, `Events`, `Waker`, `event::Source` — so the mental model (and most of
the documentation) transfers directly. Deliberate divergences are listed
[below](#divergences-from-rust-mio).

> **What this is — and isn't.** MIO is **only** the low-level readiness layer.
> It does **not** include an event loop, executor, async runtime, or buffered
> I/O. Higher layers build on top of it, exactly as Tokio builds on mio. Think
> of it as the epoll primitives, not a Tokio replacement.

## Status

Early / experimental. The API is small and the test suite covers the core
contract (Poll lifecycle, register/reregister/deregister, oneshot,
edge-triggered, EPOLLEXCLUSIVE, Waker cross-thread wakeup, timeouts). Used
by [`starlight`](https://github.com/akvilary/starlight) (also experimental).

## Platform

Linux only at the syscall level. All sources are `#if os(Linux)`, so the module
compiles on other platforms but exports nothing.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/akvilary/mio.git", from: "0.1.1")
```

```swift
.target(name: "YourTarget", dependencies: [
    .product(name: "MIO", package: "mio"),
])
```

If you only need the raw `epoll`/`eventfd` syscall wrappers (without the Swift
primitives), depend on the C target directly:

```swift
.product(name: "CMIO", package: "mio")
```

## Overview

```swift
import MIO

let poll = try Poll()
let registry = poll.registry
let events = Events(capacity: 1024)

// Register an fd for readability, tagged with a Token the kernel echoes back.
try registry.register(fd: someFD, token: Token(1), interest: .readable)

while true {
    // Block until at least one source is ready. Returns the number of events.
    _ = try poll.poll(events, timeout: .blocking)

    events.forEach { event in
        if event.isReadable {
            // event.token identifies which source became ready.
        }
    }
}
```

### Cross-thread wakeup

```swift
let waker = try Waker(registry: registry, token: Token(0))

// From any thread:
waker.wake()
// The next poll.poll() returns with a readable event on Token(0).
```

### Nanosecond-resolution timeout (Linux 5.11+)

```swift
// epoll_pwait2 with sub-millisecond timeout; falls back to ms truncation
// on kernels older than 5.11.
_ = try poll.pollNano(events, timeout: .nanoseconds(0, 500_000))  // 500 µs
```

### Thundering-herd prevention via EPOLLEXCLUSIVE

```swift
// For shared-listener multi-process servers without SO_REUSEPORT.
// Kernel delivers each accept-ready event to at most one waiter.
try registry.register(
    fd: listenerFD,
    token: Token(1),
    interest: [.readable, .exclusive]
)
```

### Swift 6.2 concurrency and ownership model

`Poll` is a **struct** wrapping a `Registry`; `Registry` is the ARC-shared
**owner** of the epoll fd. The fd is closed when the *last* reference to the
registry is released — dropping the `Poll` value itself does not close
anything. Storing a `Registry` anywhere (an event loop, a connection driver,
a worker context) keeps the epoll instance alive; there is no "keep `Poll`
alive" runtime contract. This is the ARC analogue of mio's `OwnedFd`
selector lifetime — Rust mio achieves it with `Registry::try_clone` +
`dup(2)`; here reference counting does it with one allocation and no extra
syscall. `Registry` is `Sendable` structurally, and `Equatable`/`Hashable`
by object identity (never by fd number, which the kernel recycles).

`Events` is **intentionally non-`Sendable`**: its `_count` field is mutated
by `Poll.poll` on the calling thread, and sharing it across threads would
race by design. Use one `Events` per worker thread.

`Waker` is a class **on purpose**: its role is cross-thread sharing, which
is exactly what ARC references provide (Rust callers wrap mio's `Waker` in
an `Arc` for the same effect).

## Divergences from Rust mio

Deliberate (documented in-source as well):

- **Level-triggered by default.** mio registers everything edge-triggered
  (`EPOLLET` is added unconditionally) and pushes the
  drain-until-`EAGAIN` discipline onto callers. MIO-Swift defaults to
  level-triggered — safer for hand-rolled loops — with per-registration
  opt-in via `.edge`.
- **`EPOLLRDHUP` is added automatically** to `.readable` registrations,
  matching mio, so peer half-close is observable via `event.isReadClosed`
  (suppressed for `.exclusive`, whose kernel whitelist is exactly
  `EPOLLIN | EPOLLOUT`).
- **`EINTR` is retried internally** by `poll`/`wake` instead of surfacing
  an interrupted error (mio 1.x returns `Interrupted` to the caller). The
  retry restarts with the full timeout — deadline-sensitive callers should
  use `.immediate` plus their own clock.
- **Nanosecond timeouts** via `epoll_pwait2` (Linux 5.11+) with an
  `ENOSYS` fallback to `epoll_wait` — mio only offers millisecond
  resolution.
- **`.oneshot` / `.exclusive` registration modifiers** are exposed
  (`EPOLLONESHOT`, `EPOLLEXCLUSIVE`); mio does not expose them.
- **`Waker.wake()` returns `Bool`** and treats `EAGAIN` on a saturated
  counter as delivered; mio's `wake()` returns `io::Result<()>` and
  resets+retries on `WouldBlock`. The waker is registered
  level-triggered, so the caller drains it via `reset()`.
- **`TimerFd`** — a timerfd-backed periodic timer — is included as a
  convenience for reactors; it is not part of mio's surface.

## Why?

Readiness (epoll) is the substrate underneath Tokio, and a battle-tested
alternative to `io_uring` that works on older kernels, under gVisor/old Docker,
and anywhere `epoll(7)` is available. Having the primitive layer in its own
package keeps it reusable across drivers (HTTP, Postgres, Redis, …) and
independently testable.

## License

MIT — see [LICENSE](LICENSE).
