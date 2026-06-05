"""
API binary.
- mmaps /data/index.bin (mlockall optional)
- listens on /sock/apiN.sock (UNIX SEQPACKET) for client FDs from the LB
  (via SCM_RIGHTS), OR on TCP if SOCK_PATH/CTRL_SOCK_PATH unset
- epoll edge-triggered loop, max MAX_CONNS keep-alive HTTP/1.1 conns
- One request/response -> one canned static buffer (no per-req alloc).
"""

from std.memory import UnsafePointer, memcpy
from std.os import getenv
from index_bin import open_index, Index, libc_close, libc_exit, die, libc_malloc, libc_free, score
from normalize import DIMS
from http_io import (
    parse_request,
    respond,
    REQ_INCOMPLETE,
    REQ_BAD,
    READY_RESP,
)


comptime MAX_CONNS: Int = 1024
comptime BUF_SIZE: Int = 8192

comptime AF_UNIX: Int32 = 1
comptime AF_INET: Int32 = 2
comptime SOCK_STREAM: Int32 = 1
comptime SOCK_SEQPACKET: Int32 = 5
comptime SOCK_NONBLOCK: Int32 = 0o4000
comptime SOCK_CLOEXEC: Int32 = 0o2000000
comptime SOL_SOCKET: Int32 = 1
comptime SO_REUSEADDR: Int32 = 2
comptime MSG_DONTWAIT: Int32 = 0x40
comptime MSG_NOSIGNAL: Int32 = 0x4000
comptime MSG_CMSG_CLOEXEC: Int32 = 0x40000000
comptime SCM_RIGHTS: Int32 = 1
comptime EPOLL_CLOEXEC: Int32 = 0o2000000
comptime EPOLL_CTL_ADD: Int32 = 1
comptime EPOLL_CTL_DEL: Int32 = 2
comptime EPOLL_CTL_MOD: Int32 = 3
comptime EPOLLIN: UInt32 = 0x1
comptime EPOLLOUT: UInt32 = 0x4
comptime EPOLLERR: UInt32 = 0x8
comptime EPOLLHUP: UInt32 = 0x10
comptime EPOLLRDHUP: UInt32 = 0x2000
comptime EPOLLET: UInt32 = 0x80000000
comptime MCL_CURRENT: Int32 = 1
comptime MCL_FUTURE: Int32 = 2

comptime KIND_LISTEN: UInt64 = 0
comptime KIND_CTRL_ACCEPT: UInt64 = 1
comptime KIND_CTRL_CONN: UInt64 = 2
comptime KIND_CLIENT: UInt64 = 3



@extern("unlink")
def libc_unlink(
    path: UnsafePointer[UInt8, origin=MutExternalOrigin]
) abi("c") -> Int32:
    ...


@extern("chmod")
def libc_chmod(
    path: UnsafePointer[UInt8, origin=MutExternalOrigin], mode: UInt32
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


@extern("recv")
def libc_recv(
    fd: Int32,
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    flags: Int32,
) abi("c") -> Int64:
    ...


@extern("send")
def libc_send(
    fd: Int32,
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    flags: Int32,
) abi("c") -> Int64:
    ...


@extern("recvmsg")
def libc_recvmsg(
    fd: Int32,
    mh: UnsafePointer[UInt64, origin=MutExternalOrigin],
    flags: Int32,
) abi("c") -> Int64:
    ...


@extern("epoll_create1")
def libc_epoll_create1(flags: Int32) abi("c") -> Int32:
    ...


@extern("epoll_ctl")
def libc_epoll_ctl(
    epfd: Int32,
    op: Int32,
    fd: Int32,
    ev: UnsafePointer[UInt8, origin=MutExternalOrigin],
) abi("c") -> Int32:
    ...


@extern("epoll_wait")
def libc_epoll_wait(
    epfd: Int32,
    events: UnsafePointer[UInt8, origin=MutExternalOrigin],
    maxev: Int32,
    timeout: Int32,
) abi("c") -> Int32:
    ...


@extern("mlockall")
def libc_mlockall(flags: Int32) abi("c") -> Int32:
    ...


@extern("clock_gettime")
def libc_clock_gettime(
    clk_id: Int32,
    ts: UnsafePointer[UInt8, origin=MutExternalOrigin],
) abi("c") -> Int32:
    ...


@extern("sched_yield")
def libc_sched_yield() abi("c") -> Int32:
    ...


@extern("prctl")
def libc_prctl(
    option: Int32,
    arg2: UInt64,
    arg3: UInt64,
    arg4: UInt64,
    arg5: UInt64,
) abi("c") -> Int32:
    ...


@extern("sched_setscheduler")
def libc_sched_setscheduler(
    pid: Int32,
    policy: Int32,
    param: UnsafePointer[UInt8, origin=MutExternalOrigin],
) abi("c") -> Int32:
    ...


comptime PR_SET_TIMERSLACK: Int32 = 29
comptime SCHED_FIFO: Int32 = 1

comptime CLOCK_MONOTONIC: Int32 = 1


@always_inline
def now_us() -> UInt64:
    """Monotonic microseconds, allocation-free via stack-y malloc buffer."""
    var ts = libc_malloc(16)
    var rc = libc_clock_gettime(CLOCK_MONOTONIC, ts)
    if rc != 0:
        libc_free(ts)
        return 0
    var sec = ts.bitcast[Int64]()[0]
    var nsec = (ts + 8).bitcast[Int64]()[0]
    libc_free(ts)
    return UInt64(sec) * 1000000 + UInt64(nsec) // 1000


@always_inline
def parse_int_env(name: String, default_val: Int) -> Int:
    var v = getenv(name)
    if v.byte_length() == 0:
        return default_val
    try:
        return Int(v)
    except:
        return default_val


@extern("trace_init")
def trace_init() abi("c"):
    ...


@extern("trace_msg")
def trace_msg(
    s: UnsafePointer[UInt8, origin=MutExternalOrigin], n: Int64
) abi("c"):
    ...


@always_inline
def trace(s: StaticString):
    var p = rebind[UnsafePointer[UInt8, origin=MutExternalOrigin]](
        s.unsafe_ptr()
    )
    trace_msg(p, Int64(s.byte_length()))


@always_inline
def epoll_key(kind: UInt64, val: UInt32) -> UInt64:
    return (kind << 32) | UInt64(val)


@always_inline
def epoll_kind(k: UInt64) -> UInt64:
    return k >> 32


@always_inline
def epoll_val(k: UInt64) -> UInt32:
    return UInt32(k & 0xFFFFFFFF)


comptime EPOLL_EVENT_SIZE: Int = 12


struct Conn(Copyable, Movable):
    var fd: Int32
    var in_len: UInt32
    var out_ptr: UnsafePointer[UInt8, origin=MutExternalOrigin]
    var out_len: UInt32
    var out_pos: UInt32
    var in_buf: InlineArray[UInt8, BUF_SIZE]

    def __init__(out self):
        self.fd = -1
        self.in_len = 0
        self.out_ptr = UnsafePointer[UInt8, origin=MutExternalOrigin].unsafe_dangling()
        self.out_len = 0
        self.out_pos = 0
        self.in_buf = InlineArray[UInt8, BUF_SIZE](uninitialized=True)



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
def bind_uds_listener(path: String, listen_type: Int32) -> Int32:
    var p = cstr(path)
    _ = libc_unlink(p)
    var fd = libc_socket(
        AF_UNIX, listen_type | SOCK_NONBLOCK | SOCK_CLOEXEC, Int32(0)
    )
    if fd < 0:
        die("socket AF_UNIX failed")

    comptime UN_SIZE: Int = 110
    var addr_ptr = libc_malloc(UN_SIZE)
    var z: Int = 0
    while z < UN_SIZE:
        addr_ptr[z] = 0
        z += 1
    addr_ptr[0] = UInt8(AF_UNIX & 0xFF)
    addr_ptr[1] = 0
    var L = path.byte_length()
    if L > 107:
        L = 107
    var path_ptr = rebind[UnsafePointer[UInt8, origin=MutExternalOrigin]](
        path.unsafe_ptr()
    )
    for i in range(L):
        addr_ptr[2 + i] = path_ptr[i]
    var addrlen: Int32 = Int32(2 + L + 1)
    var r = libc_bind(fd, addr_ptr, addrlen)
    libc_free(addr_ptr)
    if r < 0:
        die("bind UDS failed")
    if libc_listen(fd, Int32(512)) < 0:
        die("listen UDS failed")
    _ = libc_chmod(p, UInt32(0o666))
    libc_free(p)
    return fd


@always_inline
def bind_tcp_listener(port: UInt16) -> Int32:
    var fd = libc_socket(
        AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, Int32(0)
    )
    if fd < 0:
        die("socket AF_INET failed")
    var one_buf = libc_malloc(4)
    one_buf[0] = 1
    one_buf[1] = 0
    one_buf[2] = 0
    one_buf[3] = 0
    _ = libc_setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, one_buf, Int32(4))
    libc_free(one_buf)
    var sa_ptr = libc_malloc(16)
    var k: Int = 0
    while k < 16:
        sa_ptr[k] = 0
        k += 1
    sa_ptr[0] = UInt8(AF_INET & 0xFF)
    sa_ptr[1] = 0
    sa_ptr[2] = UInt8(port >> 8)
    sa_ptr[3] = UInt8(port & 0xFF)
    var r = libc_bind(fd, sa_ptr, Int32(16))
    libc_free(sa_ptr)
    if r < 0:
        die("bind TCP failed")
    if libc_listen(fd, Int32(512)) < 0:
        die("listen TCP failed")
    return fd


@always_inline
def cmsg_align(n: Int) -> Int:
    comptime A: Int = 8
    return (n + A - 1) & ~(A - 1)


@always_inline
def recv_scm_fd(uds_fd: Int32) -> Int32:
    """Receive a single FD via SCM_RIGHTS; -1 if WOULD_BLOCK or fatal."""
    var dummy_buf = libc_malloc(1)
    dummy_buf[0] = 0
    var iov_buf = libc_malloc(16)
    var iov_u64 = iov_buf.bitcast[UInt64]()
    iov_u64[0] = UInt64(Int(dummy_buf))
    iov_u64[1] = 1
    comptime CMSG_SPACE: Int = 24
    var ctrl_ptr = libc_malloc(CMSG_SPACE)
    var ci: Int = 0
    while ci < CMSG_SPACE:
        ctrl_ptr[ci] = 0
        ci += 1
    var mh_buf = libc_malloc(56)
    var mh_u64 = mh_buf.bitcast[UInt64]()
    mh_u64[0] = 0
    mh_u64[1] = 0
    mh_u64[2] = UInt64(Int(iov_buf))
    mh_u64[3] = 1
    mh_u64[4] = UInt64(Int(ctrl_ptr))
    mh_u64[5] = UInt64(CMSG_SPACE)
    mh_u64[6] = 0
    var r = libc_recvmsg(
        uds_fd, mh_u64, MSG_CMSG_CLOEXEC | MSG_DONTWAIT
    )
    libc_free(dummy_buf)
    libc_free(iov_buf)
    libc_free(mh_buf)
    if r <= 0:
        libc_free(ctrl_ptr)
        return -1
    var cmsg_len = ctrl_ptr.bitcast[UInt64]()[0]
    _ = cmsg_len
    var cmsg_level = (ctrl_ptr + 8).bitcast[Int32]()[0]
    var cmsg_type = (ctrl_ptr + 12).bitcast[Int32]()[0]
    if cmsg_level != SOL_SOCKET or cmsg_type != SCM_RIGHTS:
        libc_free(ctrl_ptr)
        return -1
    var data_off = cmsg_align(16)
    var fd = (ctrl_ptr + data_off).bitcast[Int32]()[0]
    libc_free(ctrl_ptr)
    return fd



struct State:
    var conns: UnsafePointer[Conn, origin=MutExternalOrigin]
    var free_idx: UnsafePointer[UInt16, origin=MutExternalOrigin]
    var free_count: Int
    var ctrl_conn_fd: Int32
    var ctrl_listen_fd: Int32
    var legacy_listen_fd: Int32
    var epfd: Int32

    def __init__(out self):
        comptime CONN_SIZE: Int = 8224
        var raw_conns = libc_malloc(MAX_CONNS * CONN_SIZE)
        self.conns = raw_conns.bitcast[Conn]()
        for i in range(MAX_CONNS):
            (self.conns + i).init_pointee_move(Conn())
        var raw_free = libc_malloc(MAX_CONNS * 2)
        self.free_idx = raw_free.bitcast[UInt16]()
        for i in range(MAX_CONNS):
            self.free_idx[i] = UInt16(MAX_CONNS - 1 - i)
        self.free_count = MAX_CONNS
        self.ctrl_conn_fd = -1
        self.ctrl_listen_fd = -1
        self.legacy_listen_fd = -1
        self.epfd = -1


@always_inline
@always_inline
def write_epoll_event(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    events: UInt32,
    data: UInt64,
):
    buf.bitcast[UInt32]()[0] = events
    (buf + 4).bitcast[UInt64]()[0] = data


@always_inline
@always_inline
def read_epoll_event_events(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
) -> UInt32:
    return buf.bitcast[UInt32]()[0]


@always_inline
@always_inline
def read_epoll_event_data(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
) -> UInt64:
    return (buf + 4).bitcast[UInt64]()[0]


@always_inline
def epoll_add(epfd: Int32, fd: Int32, key: UInt64, events: UInt32) -> Int32:
    var ev_ptr = libc_malloc(EPOLL_EVENT_SIZE)
    write_epoll_event(ev_ptr, events, key)
    var r = libc_epoll_ctl(epfd, EPOLL_CTL_ADD, fd, ev_ptr)
    libc_free(ev_ptr)
    return r


@always_inline
def epoll_mod(epfd: Int32, fd: Int32, key: UInt64, events: UInt32) -> Int32:
    var ev_ptr = libc_malloc(EPOLL_EVENT_SIZE)
    write_epoll_event(ev_ptr, events, key)
    var r = libc_epoll_ctl(epfd, EPOLL_CTL_MOD, fd, ev_ptr)
    libc_free(ev_ptr)
    return r


@always_inline
def epoll_del(epfd: Int32, fd: Int32):
    var ev_ptr = libc_malloc(EPOLL_EVENT_SIZE)
    var i: Int = 0
    while i < EPOLL_EVENT_SIZE:
        ev_ptr[i] = 0
        i += 1
    _ = libc_epoll_ctl(epfd, EPOLL_CTL_DEL, fd, ev_ptr)
    libc_free(ev_ptr)


@always_inline
def add_client_fd(mut st: State, cfd: Int32):
    if st.free_count == 0:
        _ = libc_close(cfd)
        return
    st.free_count -= 1
    var ci = Int(st.free_idx[st.free_count])
    st.conns[ci].fd = cfd
    st.conns[ci].in_len = 0
    st.conns[ci].out_ptr = UnsafePointer[UInt8, origin=MutExternalOrigin].unsafe_dangling()
    st.conns[ci].out_len = 0
    st.conns[ci].out_pos = 0
    var key = epoll_key(KIND_CLIENT, UInt32(ci))
    var r = epoll_add(
        st.epfd,
        cfd,
        key,
        EPOLLIN | EPOLLRDHUP | EPOLLET,
    )
    if r < 0:
        _ = libc_close(cfd)
        st.conns[ci].fd = -1
        st.free_idx[st.free_count] = UInt16(ci)
        st.free_count += 1


@always_inline
def close_conn(mut st: State, ci: Int):
    if st.conns[ci].fd >= 0:
        epoll_del(st.epfd, st.conns[ci].fd)
        _ = libc_close(st.conns[ci].fd)
        st.conns[ci].fd = -1
    st.conns[ci].in_len = 0
    st.conns[ci].out_ptr = UnsafePointer[UInt8, origin=MutExternalOrigin].unsafe_dangling()
    st.conns[ci].out_len = 0
    st.conns[ci].out_pos = 0
    st.free_idx[st.free_count] = UInt16(ci)
    st.free_count += 1


@always_inline
def shift_buf(mut c: Conn, consumed: Int):
    var used = consumed
    if used >= Int(c.in_len):
        c.in_len = 0
        return
    var rem = Int(c.in_len) - used
    var p = rebind[UnsafePointer[UInt8, origin=MutExternalOrigin]](
        c.in_buf.unsafe_ptr()
    )
    memcpy(dest=p, src=p + used, count=rem)
    c.in_len = UInt32(rem)


@always_inline
@always_inline
def drain_send_now(mut c: Conn) -> Bool:
    while c.out_pos < c.out_len:
        var sent = libc_send(
            c.fd,
            c.out_ptr + Int(c.out_pos),
            Int(c.out_len - c.out_pos),
            MSG_NOSIGNAL | MSG_DONTWAIT,
        )
        if sent <= 0:
            return False
        c.out_pos += UInt32(sent)
    return True


@always_inline
def drain_send(mut st: State, ci: Int):
    if drain_send_now(st.conns[ci]):
        _ = epoll_mod(
            st.epfd,
            st.conns[ci].fd,
            epoll_key(KIND_CLIENT, UInt32(ci)),
            EPOLLIN | EPOLLRDHUP | EPOLLET,
        )


@always_inline
def on_recv(mut st: State, idx: Index, ci: Int):
    var c_ptr = st.conns + ci
    while True:
        if c_ptr[].in_len >= UInt32(BUF_SIZE):
            close_conn(st, ci)
            return
        var avail = BUF_SIZE - Int(c_ptr[].in_len)
        var buf_base = rebind[
            UnsafePointer[UInt8, origin=MutExternalOrigin]
        ](c_ptr[].in_buf.unsafe_ptr())
        var p = buf_base + Int(c_ptr[].in_len)
        var got = libc_recv(c_ptr[].fd, p, avail, Int32(0))
        if got == 0:
            close_conn(st, ci)
            return
        if got < 0:
            return
        c_ptr[].in_len += UInt32(got)

        while c_ptr[].in_len > 0:
            var buf_p = rebind[
                UnsafePointer[UInt8, origin=MutExternalOrigin]
            ](c_ptr[].in_buf.unsafe_ptr())
            var parsed = parse_request(buf_p, Int(c_ptr[].in_len))
            var kind = parsed[0]
            if kind == REQ_INCOMPLETE:
                break
            if kind == REQ_BAD:
                close_conn(st, ci)
                return
            var resp = respond(idx, buf_p, parsed[1], parsed[2], kind)
            c_ptr[].out_ptr = rebind[
                UnsafePointer[UInt8, origin=MutExternalOrigin]
            ](resp.unsafe_ptr())
            c_ptr[].out_len = UInt32(resp.byte_length())
            c_ptr[].out_pos = 0
            if drain_send_now(c_ptr[]):
                shift_buf(c_ptr[], parsed[3])
                continue
            shift_buf(c_ptr[], parsed[3])
            _ = epoll_mod(
                st.epfd,
                c_ptr[].fd,
                epoll_key(KIND_CLIENT, UInt32(ci)),
                EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET,
            )
            return


@always_inline
def accept_all(mut st: State):
    var addr_ptr = libc_malloc(128)
    var addr_len_ptr = libc_malloc(4).bitcast[Int32]()
    while True:
        addr_len_ptr[0] = Int32(128)
        var cfd = libc_accept4(
            st.legacy_listen_fd,
            addr_ptr,
            addr_len_ptr,
            SOCK_NONBLOCK | SOCK_CLOEXEC,
        )
        if cfd < 0:
            libc_free(addr_ptr)
            libc_free(addr_len_ptr.bitcast[UInt8]())
            return
        add_client_fd(st, cfd)


@always_inline
def accept_ctrl(mut st: State):
    var addr_ptr = libc_malloc(128)
    var addr_len_ptr = libc_malloc(4).bitcast[Int32]()
    addr_len_ptr[0] = Int32(128)
    if st.ctrl_conn_fd >= 0:
        var cfd = libc_accept4(
            st.ctrl_listen_fd,
            addr_ptr,
            addr_len_ptr,
            SOCK_CLOEXEC,
        )
        libc_free(addr_ptr)
        libc_free(addr_len_ptr.bitcast[UInt8]())
        if cfd >= 0:
            _ = libc_close(cfd)
        return
    var cfd = libc_accept4(
        st.ctrl_listen_fd,
        addr_ptr,
        addr_len_ptr,
        SOCK_NONBLOCK | SOCK_CLOEXEC,
    )
    libc_free(addr_ptr)
    libc_free(addr_len_ptr.bitcast[UInt8]())
    if cfd < 0:
        return
    st.ctrl_conn_fd = cfd
    var r = epoll_add(
        st.epfd,
        cfd,
        epoll_key(KIND_CTRL_CONN, 0),
        EPOLLIN | EPOLLRDHUP,
    )
    if r < 0:
        _ = libc_close(cfd)
        st.ctrl_conn_fd = -1


@always_inline
def on_ctrl_recv(mut st: State):
    while True:
        var cfd = recv_scm_fd(st.ctrl_conn_fd)
        if cfd < 0:
            return
        add_client_fd(st, cfd)


@always_inline
def mlock_enabled() -> Bool:
    var v = getenv("MLOCK")
    if v.byte_length() == 0:
        return True
    return v.unsafe_ptr()[0] != UInt8(ord("0"))


def main() raises:
    var index_path_s = getenv("INDEX_PATH", default="/data/index.bin")
    var index_path = cstr(index_path_s)
    var idx = open_index(index_path)
    libc_free(index_path)

    var st = State()

    if mlock_enabled():
        _ = libc_mlockall(MCL_CURRENT | MCL_FUTURE)

    # Patch 1: prctl(PR_SET_TIMERSLACK, 1) — shrink kernel timer slack from
    # default 50us to 1ns. Cuts scheduler wake-up jitter on response paths.
    # Best-effort; ignored on failure.
    _ = libc_prctl(
        PR_SET_TIMERSLACK, UInt64(1), UInt64(0), UInt64(0), UInt64(0)
    )

    # Patch 2: sched_setscheduler(0, SCHED_FIFO, prio=10) — promote this
    # thread above SCHED_OTHER so inbound packets wake us with minimal
    # latency. Requires CAP_SYS_NICE + rtprio ulimit; best-effort otherwise.
    var rt_prio_buf = libc_malloc(4)
    rt_prio_buf.bitcast[Int32]()[0] = Int32(10)
    _ = libc_sched_setscheduler(Int32(0), SCHED_FIFO, rt_prio_buf)
    libc_free(rt_prio_buf)

    # Patch 4: self-warmup — run synthetic score() calls before opening
    # listeners so JIT/icache/dcache/centroid pages are hot when the LB
    # arrives. Duration capped by API_WARMUP_MS (default 5000ms) and
    # iteration count by API_WARMUP_ITERS (default 8000). Best-effort:
    # any failure inside score() is swallowed by Mojo's def semantics
    # but we never raise here.
    var warmup_ms: Int = parse_int_env("API_WARMUP_MS", 5000)
    var warmup_iters: Int = parse_int_env("API_WARMUP_ITERS", 8000)
    if warmup_ms > 0 and warmup_iters > 0:
        var qf_raw = libc_malloc(DIMS * 4)
        var qf = qf_raw.bitcast[Float32]()
        var w_start = now_us()
        var w_deadline = w_start + UInt64(warmup_ms) * UInt64(1000)
        var w_acc: UInt32 = 0
        var w_i: Int = 0
        while w_i < warmup_iters:
            # Synthetic float vector — covers both "legit" and "fraud"
            # neighbourhoods of the IVF space by shifting indices.
            var d: Int = 0
            while d < DIMS:
                var x = Int((w_i * 131 + d * 17) % 1000)
                qf[d] = Float32(x) / Float32(1000)
                d += 1
            if (w_i & 3) == 0:
                qf[5] = Float32(-1)
                qf[6] = Float32(-1)
            w_acc = w_acc ^ score(idx, qf)
            w_i += 1
            if (w_i & 63) == 0:
                if now_us() >= w_deadline:
                    break
        libc_free(qf_raw)
        # Force the accumulator to be live so the optimizer can't elide
        # the warmup loop body. Write to a heap byte and discard.
        var sink = libc_malloc(1)
        sink[0] = UInt8(w_acc & UInt32(0xFF))
        libc_free(sink)

    st.epfd = libc_epoll_create1(EPOLL_CLOEXEC)
    if st.epfd < 0:
        die("epoll_create1 failed")

    var ctrl_path = getenv("CTRL_SOCK_PATH")
    var sock_path = getenv("SOCK_PATH")
    if ctrl_path.byte_length() > 0:
        st.ctrl_listen_fd = bind_uds_listener(ctrl_path, SOCK_SEQPACKET)
        _ = epoll_add(
            st.epfd,
            st.ctrl_listen_fd,
            epoll_key(KIND_CTRL_ACCEPT, 0),
            EPOLLIN,
        )
    elif sock_path.byte_length() > 0:
        st.legacy_listen_fd = bind_uds_listener(sock_path, SOCK_STREAM)
        _ = epoll_add(
            st.epfd,
            st.legacy_listen_fd,
            epoll_key(KIND_LISTEN, 0),
            EPOLLIN,
        )
    else:
        var port_s = getenv("PORT", default="9999")
        var port: UInt16 = UInt16(Int(port_s))
        st.legacy_listen_fd = bind_tcp_listener(port)
        _ = epoll_add(
            st.epfd,
            st.legacy_listen_fd,
            epoll_key(KIND_LISTEN, 0),
            EPOLLIN,
        )

    var events_raw = libc_malloc(128 * EPOLL_EVENT_SIZE)

    # Dual-phase epoll: non-blocking probe -> bounded busy spin -> block.
    # EPOLL_SPIN_US: window (us) of non-blocking + sched_yield spinning
    # after the last event, before falling back to a blocking wait.
    # EPOLL_IDLE_US: timeout (us, rounded up to ms) for the eventual
    # blocking wait so the loop wakes periodically to recheck. <=0 => -1.
    var spin_us: UInt64 = UInt64(parse_int_env("EPOLL_SPIN_US", 200))
    var idle_us: Int = parse_int_env("EPOLL_IDLE_US", 5000)
    var idle_ms: Int32 = Int32(-1)
    if idle_us > 0:
        idle_ms = Int32((idle_us + 999) // 1000)
        if idle_ms < Int32(1):
            idle_ms = Int32(1)

    var last_event_us: UInt64 = now_us()
    while True:
        # Phase 1: cheap non-blocking probe (timeout=0).
        var n = libc_epoll_wait(
            st.epfd, events_raw, Int32(128), Int32(0)
        )
        if n == 0:
            # Phase 2: bounded busy spin while recently active.
            var spin_until = last_event_us + spin_us
            while now_us() < spin_until:
                _ = libc_sched_yield()
                n = libc_epoll_wait(
                    st.epfd, events_raw, Int32(128), Int32(0)
                )
                if n > 0:
                    break
                if n < 0:
                    n = 0
            # Phase 3: block (with optional idle timeout) if still idle.
            if n == 0:
                n = libc_epoll_wait(
                    st.epfd, events_raw, Int32(128), idle_ms
                )
        if n < 0:
            continue
        if n == 0:
            continue
        last_event_us = now_us()
        var i: Int = 0
        while i < Int(n):
            var ev_base = events_raw + i * EPOLL_EVENT_SIZE
            var ev_events = read_epoll_event_events(ev_base)
            var ev_data = read_epoll_event_data(ev_base)
            var k = epoll_kind(ev_data)
            if k == KIND_LISTEN:
                accept_all(st)
            elif k == KIND_CTRL_ACCEPT:
                accept_ctrl(st)
            elif k == KIND_CTRL_CONN:
                on_ctrl_recv(st)
            else:
                var ci = Int(epoll_val(ev_data))
                if (ev_events & (EPOLLHUP | EPOLLERR | EPOLLRDHUP)) != 0:
                    close_conn(st, ci)
                else:
                    if (ev_events & EPOLLOUT) != 0:
                        drain_send(st, ci)
                    if (ev_events & EPOLLIN) != 0:
                        on_recv(st, idx, ci)
            i += 1
