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

int sl_eventfd(unsigned int initval, int flags) {
    return eventfd(initval, flags);
}

#endif /* __linux__ */
