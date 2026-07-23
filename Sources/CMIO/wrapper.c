//===----------------------------------------------------------------------===//
//
//  wrapper.c
//  CMIO
//
//  Thin wrappers for epoll(7)/eventfd syscalls. `epoll_event` and
//  `sl_epoll_event` are both 12-byte packed structs with the same field
//  order, so a cast between pointers is well-defined on every supported
//  target.
//
//===----------------------------------------------------------------------===//

#define _GNU_SOURCE
#ifdef __linux__

#include "CMIO.h"
#include <sys/eventfd.h>
#include <sys/epoll.h>
#include <stddef.h>
#include <errno.h>

int sl_epoll_create1(void) {
    int fd = epoll_create1(EPOLL_CLOEXEC);
    return fd < 0 ? -errno : fd;
}

int sl_epoll_ctl_add(int epfd, int fd, uint32_t events, uint64_t data) {
    struct epoll_event ev;
    ev.events = events;
    ev.data.u64 = data;
    return epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev) < 0 ? -errno : 0;
}

int sl_epoll_ctl_mod(int epfd, int fd, uint32_t events, uint64_t data) {
    struct epoll_event ev;
    ev.events = events;
    ev.data.u64 = data;
    return epoll_ctl(epfd, EPOLL_CTL_MOD, fd, &ev) < 0 ? -errno : 0;
}

int sl_epoll_ctl_del(int epfd, int fd) {
    return epoll_ctl(epfd, EPOLL_CTL_DEL, fd, NULL) < 0 ? -errno : 0;
}

int sl_epoll_wait(int epfd, sl_epoll_event *events, int maxevents, int timeout) {
    int n = epoll_wait(epfd, (struct epoll_event *)events, maxevents, timeout);
    return n < 0 ? -errno : n;
}

int sl_epoll_pwait2(
    int epfd,
    sl_epoll_event *events,
    int maxevents,
    long timeout_sec,
    long timeout_nsec,
    const void *sigmask,
    unsigned long sigsetsize
) {
    struct timespec ts;
    ts.tv_sec  = (time_t)timeout_sec;
    ts.tv_nsec = (long)timeout_nsec;
    int n = epoll_pwait2(
        epfd,
        (struct epoll_event *)events,
        maxevents,
        &ts,
        (const sigset_t *)sigmask
    );
    // Note: `sigsetsize` is accepted by the underlying syscall but glibc's
    // epoll_pwait2 wrapper does not expose it — `sizeof(sigset_t)` is used
    // internally. The parameter remains in our shim for forward compat
    // with raw syscall() invocations.
    (void)sigsetsize;
    return n < 0 ? -errno : n;
}

int sl_eventfd(unsigned int initval, int flags) {
    int fd = eventfd(initval, flags);
    return fd < 0 ? -errno : fd;
}

#endif /* __linux__ */
