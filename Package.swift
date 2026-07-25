// swift-tools-version: 6.2
//
//  mio — a Swift port of Rust's mio (https://github.com/tokio-rs/mio):
//  lightweight, portable readiness-based I/O primitives backed by epoll
//  on Linux. Mirrors mio's `Poll` / `Registry` / `Token` / `Interest` /
//  `Ready` / `Event` / `Events` / `Waker` / `event::Source` surface 1:1.
//
//  This package is deliberately ONLY the low-level primitives — it does
//  NOT include an event loop, executor, or async runtime. Higher layers
//  (e.g. Starlight's PollEventLoop) build on top of it, just as tokio
//  builds on mio.
import PackageDescription

let package = Package(
    name: "mio",
    products: [
        .library(name: "MIO", targets: ["MIO"]),
        // CMIO is also exposed as its own product so non-mio consumers
        // that just need the epoll/eventfd syscall wrappers (e.g. an
        // io_uring backend needing eventfd) can depend on it directly
        // without pulling in the Swift primitives — and without each
        // consumer redefining the same C symbols (which would clash at
        // link time).
        .library(name: "CMIO", targets: ["CMIO"]),
    ],
    targets: [
        // ── C wrappers for the epoll/eventfd syscalls Swift's Glibc
        //    module does not re-export. Kept minimal and self-contained
        //    so the package has no external dependencies.
        .target(
            name: "CMIO",
            path: "Sources/CMIO",
            publicHeadersPath: "include"
        ),

        // ── mio analog (Linux only at the syscall level; guarded with
        //    `#if os(Linux)` so the module compiles everywhere).
        .target(
            name: "MIO",
            dependencies: ["CMIO"],
            path: "Sources/MIO",
            swiftSettings: baseSwiftSettings
        ),

        .testTarget(
            name: "MIOTests",
            dependencies: ["MIO"],
            path: "Tests/MIOTests",
            swiftSettings: baseSwiftSettings
        ),
    ]
)

// Swift 6.2 settings — load-bearing for compatibility with downstream
// consumers (starlight) that enable the same experimental features.
// Without these, methods on `~Copyable` types in MIO are silently
// hidden from consumers with stricter memory-safety / lifetime flags
// (verified empirically: Swift 6.2's type checker refuses to expose
// `mutating` methods on `~Copyable` structs across module boundaries
// unless the consumer's experimental-feature set matches the producer's).
var baseSwiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("StrictMemorySafety"),
    ]
}
