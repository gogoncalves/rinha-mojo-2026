"""
Loadbalancer binary.

Listens on TCP :9999, accepts client sockets, distributes them round-robin
to api1/api2 by sending the client FD over a UNIX SEQPACKET socket via
SCM_RIGHTS ancillary control message. Same protocol as Zig v31.

Env:
- LB_PORT          (9999)
- LB_BACKLOG       (4096)
- LB_ACCEPT_BATCH  (128)
- API_SOCKETS      comma-separated UDS paths.
"""

from std.memory import UnsafePointer, memcpy
from std.os import getenv
from std.time import sleep


comptime MAX_BACKENDS: Int = 8
comptime AF_UNIX: Int32 = 1
comptime AF_INET: Int32 = 2
comptime SOCK_STREAM: Int32 = 1
comptime SOCK_SEQPACKET: Int32 = 5
comptime SOCK_NONBLOCK: Int32 = 0o4000
comptime SOCK_CLOEXEC: Int32 = 0o2000000
comptime SOL_SOCKET: Int32 = 1
comptime SO_REUSEADDR: Int32 = 2
comptime SO_REUSEPORT: Int32 = 15
comptime SO_SNDBUF: Int32 = 7
comptime IPPROTO_TCP: Int32 = 6
comptime TCP_NODELAY: Int32 = 1
comptime TCP_DEFER_ACCEPT: Int32 = 9
comptime TCP_QUICKACK: Int32 = 12
comptime MSG_NOSIGNAL: Int32 = 0x4000
comptime MSG_DONTWAIT: Int32 = 0x40
comptime SCM_RIGHTS: Int32 = 1
comptime POLLIN: Int16 = 1
comptime F_OK: Int32 = 0


@extern("malloc")
def libc_malloc(n: Int) abi("c") -> UnsafePointer[
    UInt8, origin=MutExternalOrigin
]:
    ...


@extern("free")
def libc_free(p: UnsafePointer[UInt8, origin=MutExternalOrigin]) abi("c"):
    ...


@extern("exit")
def libc_exit(code: Int32) abi("c"):
    ...


@always_inline
def die(msg: StaticString):
    print(msg)
    libc_exit(Int32(1))


@extern("access")
def libc_access(
    path: UnsafePointer[UInt8, origin=MutExternalOrigin], mode: Int32
) abi("c") -> Int32:
    ...


@extern("socket")
def libc_socket(family: Int32, ty: Int32, proto: Int32) abi("c") -> Int32:
    ...


@extern("setsockopt")
def libc_setsockopt(
    fd: Int32,
    level: Int32,
    optname: Int32,
    optval: UnsafePointer[UInt8, origin=MutExternalOrigin],
    optlen: Int32,
) abi("c") -> Int32:
    ...


@extern("connect")
def libc_connect(
    fd: Int32,
    addr: UnsafePointer[UInt8, origin=MutExternalOrigin],
    addrlen: Int32,
) abi("c") -> Int32:
    ...


@extern("bind")
def libc_bind(
    fd: Int32,
    addr: UnsafePointer[UInt8, origin=MutExternalOrigin],
    addrlen: Int32,
) abi("c") -> Int32:
    ...


@extern("listen")
def libc_listen(fd: Int32, backlog: Int32) abi("c") -> Int32:
    ...


@extern("accept4")
def libc_accept4(
    fd: Int32,
    addr: UnsafePointer[UInt8, origin=MutExternalOrigin],
    addrlen: UnsafePointer[Int32, origin=MutExternalOrigin],
    flags: Int32,
) abi("c") -> Int32:
    ...


@extern("close")
def libc_close(fd: Int32) abi("c") -> Int32:
    ...


@extern("sendmsg")
def libc_sendmsg(
    fd: Int32,
    mh: UnsafePointer[UInt64, origin=MutExternalOrigin],
    flags: Int32,
) abi("c") -> Int64:
    ...


@extern("poll")
def libc_poll(
    pfds: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: UInt32,
    timeout: Int32,
) abi("c") -> Int32:
    ...


@always_inline
def cmsg_align(n: Int) -> Int:
    comptime A: Int = 8
    return (n + A - 1) & ~(A - 1)


@always_inline
def cstr(s: String) -> UnsafePointer[UInt8, origin=MutExternalOrigin]:
    var L = s.byte_length()
    var p = libc_malloc(L + 1)
    var src = rebind[UnsafePointer[UInt8, origin=MutExternalOrigin]](
        s.unsafe_ptr()
    )
    memcpy(dest=p, src=src, count=L)
    p[L] = 0
    return p


@always_inline
def wait_for_path(path: String):
    var p = cstr(path)
    for _ in range(600):
        if libc_access(p, F_OK) == 0:
            libc_free(p)
            return
        sleep(0.1)
    libc_free(p)
    die("backend socket timeout")


@always_inline
def connect_uds(path: String) -> Int32:
    var fd = libc_socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, Int32(0))
    if fd < 0:
        die("socket UDS failed")
    var sndbuf_buf = libc_malloc(4)
    # 256*1024 = 0x40000 little-endian: 0x00, 0x00, 0x04, 0x00
    sndbuf_buf[0] = UInt8(0)
    sndbuf_buf[1] = UInt8(0)
    sndbuf_buf[2] = UInt8(4)
    sndbuf_buf[3] = UInt8(0)
    _ = libc_setsockopt(fd, SOL_SOCKET, SO_SNDBUF, sndbuf_buf, Int32(4))
    libc_free(sndbuf_buf)

    comptime UN_SIZE: Int = 110
    var addr_buf = libc_malloc(UN_SIZE)
    var i: Int = 0
    while i < UN_SIZE:
        addr_buf[i] = 0
        i += 1
    addr_buf[0] = UInt8(AF_UNIX & 0xFF)
    addr_buf[1] = 0
    var L = path.byte_length()
    if L > 107:
        L = 107
    var path_ptr = rebind[UnsafePointer[UInt8, origin=MutExternalOrigin]](
        path.unsafe_ptr()
    )
    for j in range(L):
        addr_buf[2 + j] = path_ptr[j]
    var r = libc_connect(fd, addr_buf, Int32(2 + L + 1))
    libc_free(addr_buf)
    if r < 0:
        die("connect UDS failed")
    return fd


@always_inline
def bind_tcp_listener(port: UInt16, backlog: Int32) -> Int32:
    var fd = libc_socket(
        AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, Int32(0)
    )
    if fd < 0:
        die("socket TCP failed")
    var one_buf = libc_malloc(4)
    one_buf[0] = 1
    one_buf[1] = 0
    one_buf[2] = 0
    one_buf[3] = 0
    _ = libc_setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, one_buf, Int32(4))
    _ = libc_setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, one_buf, Int32(4))
    _ = libc_setsockopt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, one_buf, Int32(4))
    libc_free(one_buf)

    var sa_buf = libc_malloc(16)
    var i: Int = 0
    while i < 16:
        sa_buf[i] = 0
        i += 1
    sa_buf[0] = UInt8(AF_INET & 0xFF)
    sa_buf[1] = 0
    sa_buf[2] = UInt8(port >> 8)
    sa_buf[3] = UInt8(port & 0xFF)
    var r = libc_bind(fd, sa_buf, Int32(16))
    libc_free(sa_buf)
    if r < 0:
        die("bind TCP failed")
    if libc_listen(fd, backlog) < 0:
        die("listen TCP failed")
    return fd


@always_inline
def send_fd(uds_fd: Int32, client_fd: Int32) -> Bool:
    var dummy_buf = libc_malloc(1)
    dummy_buf[0] = 1

    var iov_buf = libc_malloc(16)  # 2 x UInt64
    var iov_u64 = iov_buf.bitcast[UInt64]()
    iov_u64[0] = UInt64(Int(dummy_buf))
    iov_u64[1] = 1

    comptime CMSG_SPACE: Int = 24
    var ctrl_buf = libc_malloc(CMSG_SPACE)
    var i: Int = 0
    while i < CMSG_SPACE:
        ctrl_buf[i] = 0
        i += 1
    var clen = cmsg_align(16) + 4
    ctrl_buf.bitcast[UInt64]()[0] = UInt64(clen)
    (ctrl_buf + 8).bitcast[Int32]()[0] = SOL_SOCKET
    (ctrl_buf + 12).bitcast[Int32]()[0] = SCM_RIGHTS
    var data_off = cmsg_align(16)
    (ctrl_buf + data_off).bitcast[Int32]()[0] = client_fd

    var mh_buf = libc_malloc(56)  # 7 x UInt64
    var mh_u64 = mh_buf.bitcast[UInt64]()
    mh_u64[0] = 0
    mh_u64[1] = 0
    mh_u64[2] = UInt64(Int(iov_buf))
    mh_u64[3] = 1
    mh_u64[4] = UInt64(Int(ctrl_buf))
    mh_u64[5] = UInt64(clen)
    mh_u64[6] = 0

    # Blocking sendmsg (no MSG_DONTWAIT): if the backend's SEQPACKET buffer is
    # temporarily full, we block briefly rather than drop the client FD,
    # mirroring Zig v36 behavior. Backend processes a packet fast enough that
    # this is bounded; under saturation this gives natural backpressure.
    var r = libc_sendmsg(uds_fd, mh_u64, MSG_NOSIGNAL)
    libc_free(dummy_buf)
    libc_free(iov_buf)
    libc_free(ctrl_buf)
    libc_free(mh_buf)
    return r > 0


def main() raises:
    var port_s = getenv("LB_PORT", default="9999")
    var port: UInt16 = UInt16(Int(port_s))
    var backlog_s = getenv("LB_BACKLOG", default="4096")
    var backlog: Int32 = Int32(Int(backlog_s))
    var batch_s = getenv("LB_ACCEPT_BATCH", default="128")
    var accept_batch: Int = Int(batch_s)
    var sockets_s = getenv("API_SOCKETS")
    if sockets_s.byte_length() == 0:
        die("API_SOCKETS env required")

    var paths = sockets_s.split(",")
    var nb: Int = 0
    var backend_fds = InlineArray[Int32, MAX_BACKENDS](fill=Int32(-1))
    for raw in paths:
        var stripped = raw.strip()
        if stripped.byte_length() == 0:
            continue
        if nb >= MAX_BACKENDS:
            break
        var p = String(stripped)
        wait_for_path(p)
        backend_fds[nb] = connect_uds(p)
        nb += 1
    if nb == 0:
        die("no backends")

    var lfd = bind_tcp_listener(port, backlog)
    var rr: Int = 0
    var addr_ptr = libc_malloc(128)
    var addr_len_ptr = libc_malloc(4).bitcast[Int32]()
    while True:
        var accepted: Int = 0
        var got_one: Bool = False
        while accepted < accept_batch:
            addr_len_ptr[0] = Int32(128)
            var cfd = libc_accept4(
                lfd,
                addr_ptr,
                addr_len_ptr,
                SOCK_NONBLOCK | SOCK_CLOEXEC,
            )
            if cfd < 0:
                break
            got_one = True
            var one_buf = libc_malloc(4)
            one_buf[0] = 1
            one_buf[1] = 0
            one_buf[2] = 0
            one_buf[3] = 0
            _ = libc_setsockopt(
                cfd, IPPROTO_TCP, TCP_NODELAY, one_buf, Int32(4)
            )
            _ = libc_setsockopt(
                cfd, IPPROTO_TCP, TCP_QUICKACK, one_buf, Int32(4)
            )
            libc_free(one_buf)
            var start = rr
            var attempt: Int = 0
            while attempt < nb:
                var bi = (start + attempt) % nb
                if send_fd(backend_fds[bi], cfd):
                    rr = (bi + 1) % nb
                    break
                attempt += 1
            _ = libc_close(cfd)
            accepted += 1
        if not got_one:
            var pfd_buf = libc_malloc(8)
            pfd_buf.bitcast[Int32]()[0] = lfd
            (pfd_buf + 4).bitcast[Int16]()[0] = POLLIN
            (pfd_buf + 6).bitcast[Int16]()[0] = 0
            _ = libc_poll(pfd_buf, UInt32(1), Int32(60000))
            libc_free(pfd_buf)
