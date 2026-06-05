/*
 * lb.c - TCP -> UDS(SEQPACKET) load balancer with SCM_RIGHTS FD passing.
 *
 * Ported to C from src/lb.mojo (v6) to match the rival lucasmontano reference
 * implementation. Prefix-byte protocol (1-byte dummy payload + ancillary
 * SCM_RIGHTS control message) is preserved so the existing Mojo worker
 * (src/main.mojo recv_scm_fd) keeps working untouched.
 *
 * Env:
 *   LB_PORT          (default 9999)
 *   LB_BACKLOG       (default 4096)
 *   LB_ACCEPT_BATCH  (default 128)
 *   API_SOCKETS      comma-separated UDS paths (default /sock/api1.sock,/sock/api2.sock)
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* SO_BUSY_POLL is in <asm/socket.h> on some headers, fall back. */
#ifndef SO_BUSY_POLL
#define SO_BUSY_POLL 46
#endif
#ifndef SO_INCOMING_CPU
#define SO_INCOMING_CPU 49
#endif
#ifndef TCP_FASTOPEN
#define TCP_FASTOPEN 23
#endif

/* Branch-hint macros: only annotate paths with a clear bias. */
#define likely(x)   __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)
/* EPIOCSPARAMS: epoll_busy_poll ioctl (Linux 6.9+). Magic = 0x40087001. */
#ifndef EPIOCSPARAMS
struct epoll_params_compat {
    unsigned int busy_poll_usecs;
    unsigned short busy_poll_budget;
    unsigned char prefer_busy_poll;
    unsigned char pad;
};
#define EPIOCSPARAMS _IOW('@', 1, struct epoll_params_compat)
#endif

#define MAX_BACKENDS 32
#define DEFAULT_ACCEPT_BATCH 128

typedef struct {
    int fd;
    unsigned char dummy;       /* 1-byte prefix payload carried alongside SCM_RIGHTS */
    struct iovec iov;
    union {
        struct cmsghdr cm;
        char buf[CMSG_SPACE(sizeof(int))];
    } control;
    struct msghdr msg;
    struct cmsghdr *cmsg;
} backend_t;

static int getenv_int(const char *name, int fallback) {
    const char *v = getenv(name);
    if (!v || !*v) return fallback;
    int parsed = atoi(v);
    return parsed > 0 ? parsed : fallback;
}

static int connect_backend(const char *path) {
    int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    int sndbuf = 256 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void init_backend(backend_t *b, int fd) {
    memset(b, 0, sizeof(*b));
    b->fd = fd;
    b->dummy = 1;                       /* prefix byte */
    b->iov.iov_base = &b->dummy;
    b->iov.iov_len = 1;
    b->msg.msg_iov = &b->iov;
    b->msg.msg_iovlen = 1;
    b->msg.msg_control = b->control.buf;
    b->msg.msg_controllen = sizeof(b->control.buf);
    b->cmsg = CMSG_FIRSTHDR(&b->msg);
    b->cmsg->cmsg_level = SOL_SOCKET;
    b->cmsg->cmsg_type = SCM_RIGHTS;
    b->cmsg->cmsg_len = CMSG_LEN(sizeof(int));
}

static int wait_for_socket(const char *path) {
    int tries = 0;
    while (tries++ < 600) {
        struct stat st;
        if (stat(path, &st) == 0) return 0;
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000 };
        nanosleep(&ts, NULL);
    }
    return -1;
}

static int send_fd_with_flags(backend_t *dst, int fd, int flags) {
    dst->msg.msg_controllen = sizeof(dst->control.buf);
    memcpy(CMSG_DATA(dst->cmsg), &fd, sizeof(int));
    for (;;) {
        ssize_t r = sendmsg(dst->fd, &dst->msg, MSG_NOSIGNAL | flags);
        if (r > 0) return 0;
        if (r < 0 && errno == EINTR) continue;
        return -1;
    }
}

static int send_fd(backend_t *dst, int fd) {
    return send_fd_with_flags(dst, fd, MSG_DONTWAIT);
}

static int send_fd_blocking(backend_t *dst, int fd) {
    return send_fd_with_flags(dst, fd, 0);
}

static int parse_backends(const char *env, char *paths[MAX_BACKENDS]) {
    int n = 0;
    char *tmp = strdup(env);
    char *save = NULL;
    char *tok = strtok_r(tmp, ",", &save);
    while (tok && n < MAX_BACKENDS) {
        /* trim whitespace */
        while (*tok == ' ' || *tok == '\t') tok++;
        size_t l = strlen(tok);
        while (l > 0 && (tok[l-1] == ' ' || tok[l-1] == '\t' || tok[l-1] == '\n')) {
            tok[--l] = '\0';
        }
        if (*tok) paths[n++] = strdup(tok);
        tok = strtok_r(NULL, ",", &save);
    }
    free(tmp);
    return n;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    signal(SIGPIPE, SIG_IGN);

    int port = getenv_int("LB_PORT", 9999);
    int backlog = getenv_int("LB_BACKLOG", 4096);
    int accept_batch = getenv_int("LB_ACCEPT_BATCH", DEFAULT_ACCEPT_BATCH);
    const char *socks_env = getenv("API_SOCKETS");
    if (!socks_env || !*socks_env) socks_env = "/sock/api1.sock,/sock/api2.sock";

    char *paths[MAX_BACKENDS] = {0};
    int nb = parse_backends(socks_env, paths);
    if (nb <= 0) {
        fprintf(stderr, "[lb] no backends\n");
        return 2;
    }

    backend_t backends[MAX_BACKENDS];
    for (int i = 0; i < nb; i++) {
        fprintf(stderr, "[lb] waiting for %s\n", paths[i]);
        if (wait_for_socket(paths[i]) < 0) {
            fprintf(stderr, "[lb] timeout waiting for %s\n", paths[i]);
            return 3;
        }
        int fd = -1;
        for (int t = 0; t < 100; t++) {
            fd = connect_backend(paths[i]);
            if (fd >= 0) break;
            struct timespec ts = { .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000 };
            nanosleep(&ts, NULL);
        }
        if (fd < 0) {
            fprintf(stderr, "[lb] failed connecting %s\n", paths[i]);
            return 4;
        }
        init_backend(&backends[i], fd);
        fprintf(stderr, "[lb] connected to %s (fd=%d)\n", paths[i], fd);
    }

    int lfd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (lfd < 0) {
        perror("socket");
        return 5;
    }
    int on = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    setsockopt(lfd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on));
    setsockopt(lfd, IPPROTO_TCP, TCP_DEFER_ACCEPT, &on, sizeof(on));
    /* SO_BUSY_POLL: tell the kernel to spin in the NAPI poll loop for up
     * to N usecs before parking, cutting accept latency on small-RPS
     * bursts (top-piassa uses 50us). Best-effort, ignored on old kernels. */
    int busy_us = 50;
    (void)setsockopt(lfd, SOL_SOCKET, SO_BUSY_POLL, &busy_us, sizeof(busy_us));

    /* TCP_FASTOPEN: enable server-side TFO so clients that support it can
     * stuff payload into the SYN and skip an RTT. Best-effort; ignored
     * silently on kernels without TFO or when /proc/sys/net/ipv4/tcp_fastopen
     * is disabled. Queue length 256 mirrors top-piassa-asm/lb.asm:188. */
    {
        int qlen = 256;
        (void)setsockopt(lfd, IPPROTO_TCP, TCP_FASTOPEN, &qlen, sizeof(qlen));
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 6;
    }
    if (listen(lfd, backlog) < 0) {
        perror("listen");
        return 7;
    }

    fprintf(stderr, "[lb] listening :%d backlog=%d batch=%d, %d backends\n",
            port, backlog, accept_batch, nb);

    int rr = 0;
    for (;;) {
        int accepted = 0;
        while (accepted < accept_batch) {
            int cfd = accept4(lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
            if (unlikely(cfd < 0)) {
                if (errno == EINTR) continue;
                break;
            }
            accepted++;
            int one = 1;
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            setsockopt(cfd, IPPROTO_TCP, TCP_QUICKACK, &one, sizeof(one));

            /* Patch 6: intercept GET /ready locally so the LB answers
             * health checks without round-tripping through the SCM_RIGHTS
             * fd-pass + Mojo epoll path. MSG_PEEK keeps the bytes in the
             * recv buffer if the request is not /ready, so the real client
             * data still goes to the backend untouched. */
            {
                char peek_buf[64];
                ssize_t pn = recv(cfd, peek_buf, sizeof(peek_buf) - 1,
                                  MSG_PEEK | MSG_DONTWAIT);
                if (unlikely(pn >= 10 && memcmp(peek_buf, "GET /ready", 10) == 0)) {
                    static const char ready_resp[] =
                        "HTTP/1.1 200 OK\r\n"
                        "Content-Length: 2\r\n"
                        "Connection: close\r\n"
                        "\r\nok";
                    (void)send(cfd, ready_resp, sizeof(ready_resp) - 1,
                               MSG_NOSIGNAL);
                    close(cfd);
                    continue;
                }
            }

            int target = rr;
            rr = (rr + 1) % nb;
            if (unlikely(send_fd(&backends[target], cfd) != 0)) {
                /* retry on another backend, then fall back to blocking */
                int sent = 0;
                for (int k = 1; k < nb && !sent; k++) {
                    int alt = (target + k) % nb;
                    if (send_fd(&backends[alt], cfd) == 0) {
                        rr = (alt + 1) % nb;
                        sent = 1;
                    }
                }
                if (!sent) {
                    (void)send_fd_blocking(&backends[target], cfd);
                }
            }
            close(cfd);
        }
        if (accepted == 0) {
            struct pollfd pfd = { .fd = lfd, .events = POLLIN, .revents = 0 };
            poll(&pfd, 1, -1);
        }
    }
}
