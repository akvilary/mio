//===----------------------------------------------------------------------===//
//
//  CMIO.h
//  CMIO
//
//  Thin wrappers for the epoll/eventfd syscalls that Swift's Glibc module
//  does not re-export. Self-contained — no dependencies beyond the kernel.
//
//===----------------------------------------------------------------------===//

#ifndef CMIO_H
#define CMIO_H

#ifdef __linux__

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─── epoll wrappers ────────────────────────────────────────────────────
//
// Swift's Glibc module does not expose <sys/epoll.h>. These mirror the
// kernel's 12-byte `struct epoll_event` exactly.
//
// `sl_epoll_event` is declared `__packed__` to match the kernel ABI
// (4-byte events + 8-byte data, no padding). epoll_wait(2) writes
// contiguous 12-byte records into the caller-supplied buffer; any
// compiler-inserted padding would corrupt the result.

/// Mirror of `struct epoll_event` from <sys/epoll.h>.
/// 12 bytes, packed. `data` carries the user-supplied Token (u64).
typedef struct __attribute__((packed)) sl_epoll_event {
    uint32_t events;   /* EPOLLIN | EPOLLOUT | ... */
    uint64_t data;     /* Token raw value */
} sl_epoll_event;

/// Create an epoll fd with EPOLL_CLOEXEC. Wrapper around epoll_create1(2).
/// Returns fd >= 0, or -errno on failure.
int sl_epoll_create1(void);

/// Add `fd` to the epoll interest list. Wrapper around
/// epoll_ctl(epfd, EPOLL_CTL_ADD, fd, ev). Returns 0 on success, -errno
/// on failure.
int sl_epoll_ctl_add(int epfd, int fd, uint32_t events, uint64_t data);

/// Modify an already-registered `fd`. Wrapper around
/// epoll_ctl(epfd, EPOLL_CTL_MOD, fd, ev). Returns 0 on success, -errno
/// on failure.
int sl_epoll_ctl_mod(int epfd, int fd, uint32_t events, uint64_t data);

/// Remove `fd` from the epoll interest list. Wrapper around
/// epoll_ctl(epfd, EPOLL_CTL_DEL, fd, NULL). Returns 0 on success,
/// -errno on failure.
int sl_epoll_ctl_del(int epfd, int fd);

/// Block waiting for events. Wrapper around epoll_wait(2).
/// Writes up to `maxevents` records into `events` (caller-allocated).
/// Returns the number of events delivered, 0 on timeout, or -errno on
/// failure (EINTR is reported as -EINTR; the caller may retry).
int sl_epoll_wait(int epfd, sl_epoll_event *events, int maxevents, int timeout);

/// Block waiting for events with nanosecond-resolution timeout. Wrapper
/// around epoll_pwait2(2) (Linux 5.11+). `timeout_sec`/`timeout_nsec`
/// follow `struct timespec` conventions: negative `tv_sec` means block
/// forever, 0/0 means non-blocking poll. The signal mask (`sigmask`,
/// may be NULL) is atomically installed for the duration of the wait.
///
/// Returns the number of events, 0 on timeout, or -errno on failure.
/// -ENOSYS is reported on kernels < 5.11; callers should fall back to
/// `sl_epoll_wait` if they need to support older kernels.
int sl_epoll_pwait2(
    int epfd,
    sl_epoll_event *events,
    int maxevents,
    long timeout_sec,
    long timeout_nsec,
    const void *sigmask,
    unsigned long sigsetsize
);

// ─── eventfd wrapper ───────────────────────────────────────────────────

/// Create an eventfd. Wrapper around eventfd(2). Returns fd >= 0 on
/// success, -errno on failure (consistent with the epoll wrappers).
int sl_eventfd(unsigned int initval, int flags);

#ifdef __cplusplus
}
#endif

#endif /* __linux__ */
#endif /* CMIO_H */
