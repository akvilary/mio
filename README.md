# MIO

A Swift port of [**mio** (Rust)](https://github.com/tokio-rs/mio): lightweight,
portable, readiness-based I/O primitives backed by `epoll` on Linux. The public
surface mirrors mio 1:1 — `Poll`, `Registry`, `Token`, `Interest`, `Ready`,
`Event`, `Events`, `Waker`, `event::Source` — so the mental model (and most of
the documentation) transfers directly.

> **What this is — and isn't.** MIO is **only** the low-level readiness layer.
> It does **not** include an event loop, executor, async runtime, or buffered
> I/O. Higher layers build on top of it, exactly as Tokio builds on mio. Think
> of it as the epoll primitives, not a Tokio replacement.

## Status

Early / experimental. The API is small and the test suite covers the core
contract (Poll lifecycle, register/reregister/deregister, oneshot, Waker
cross-thread wakeup, timeouts). Used in production by
[`starlight`](https://github.com/akvilary/starlight).

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

## Why?

Readiness (epoll) is the substrate underneath Tokio, and a battle-tested
alternative to `io_uring` that works on older kernels, under gVisor/old Docker,
and anywhere `epoll(7)` is available. Having the primitive layer in its own
package keeps it reusable across drivers (HTTP, Postgres, Redis, …) and
independently testable.

## License

MIT — see [LICENSE](LICENSE).
