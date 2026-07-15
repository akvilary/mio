// swift-tools-version: 6.0
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
            path: "Sources/MIO"
        ),

        .testTarget(
            name: "MIOTests",
            dependencies: ["MIO"],
            path: "Tests/MIOTests"
        ),
    ]
)
