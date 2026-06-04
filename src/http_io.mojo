"""
Minimal HTTP/1.1 request parsing + canned responses.

We only care about two endpoints:
- POST /fraud-score   { ...payload }       -> 200 JSON, one of 6 canned bodies
- GET  /ready                              -> 200 "ok"

Every other request -> 404.

Responses are pre-rendered so the hot path never allocates.
"""

from std.memory import UnsafePointer
from json_parse import parse, Payload, KNOWN_PTRS_BYTES, KNOWN_LENS_BYTES
from normalize import vectorize, DIMS
from index_bin import Index, score, libc_malloc, libc_free


comptime REQ_INCOMPLETE: Int = -1
comptime REQ_BAD: Int = -2
comptime REQ_GET_READY: Int = 0
comptime REQ_POST_SCORE: Int = 1
comptime REQ_OTHER: Int = 2


comptime READY_RESP: StaticString = (
    "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n"
    "content-length: 2\r\nconnection: keep-alive\r\n\r\nok"
)

comptime NOT_FOUND_RESP: StaticString = (
    "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n"
    "connection: keep-alive\r\n\r\n"
)

comptime APPROVED_HDR: StaticString = (
    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n"
    "content-length: 35\r\nconnection: keep-alive\r\n\r\n"
)
comptime DENIED_HDR: StaticString = (
    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n"
    "content-length: 36\r\nconnection: keep-alive\r\n\r\n"
)

comptime SCORE_0: StaticString = APPROVED_HDR + '{"approved":true,"fraud_score":0.0}'
comptime SCORE_1: StaticString = APPROVED_HDR + '{"approved":true,"fraud_score":0.2}'
comptime SCORE_2: StaticString = APPROVED_HDR + '{"approved":true,"fraud_score":0.4}'
comptime SCORE_3: StaticString = DENIED_HDR + '{"approved":false,"fraud_score":0.6}'
comptime SCORE_4: StaticString = DENIED_HDR + '{"approved":false,"fraud_score":0.8}'
comptime SCORE_5: StaticString = DENIED_HDR + '{"approved":false,"fraud_score":1.0}'


@always_inline
def score_resp(frauds: UInt32) -> StaticString:
    var f = frauds if frauds <= 5 else UInt32(5)
    if f == 0:
        return SCORE_0
    if f == 1:
        return SCORE_1
    if f == 2:
        return SCORE_2
    if f == 3:
        return SCORE_3
    if f == 4:
        return SCORE_4
    return SCORE_5


@always_inline
def starts_with(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    lit: StaticString,
) -> Bool:
    var L = lit.byte_length()
    if n < L:
        return False
    for i in range(L):
        if buf[i] != UInt8(ord(lit[byte=i])):
            return False
    return True


@always_inline
def ascii_lower(c: UInt8) -> UInt8:
    if c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
        return c + 32
    return c


def find_crlf2(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin], n: Int
) -> Int:
    """Return index of CRLF-CRLF end, or -1 if not present."""
    if n < 4:
        return -1
    var i: Int = 0
    var limit = n - 3
    while i < limit:
        if (
            buf[i] == UInt8(ord("\r"))
            and buf[i + 1] == UInt8(ord("\n"))
            and buf[i + 2] == UInt8(ord("\r"))
            and buf[i + 3] == UInt8(ord("\n"))
        ):
            return i
        i += 1
    return -1


def parse_content_length(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin], hdr_end: Int
) -> Int:
    """Scan header range for 'Content-Length:' (case-insensitive). -1 if missing."""
    var i: Int = 0
    while i < hdr_end:
        var nl = i
        while nl < hdr_end and buf[nl] != UInt8(ord("\n")):
            nl += 1
        var line_end = nl
        if line_end > i and buf[line_end - 1] == UInt8(ord("\r")):
            line_end -= 1
        var line_len = line_end - i
        if line_len >= 15:
            var ok: Bool = True
            var lit: StaticString = "content-length:"
            for j in range(15):
                if ascii_lower(buf[i + j]) != UInt8(ord(lit[byte=j])):
                    ok = False
                    break
            if ok:
                var p = i + 15
                while p < line_end and (
                    buf[p] == UInt8(ord(" ")) or buf[p] == UInt8(ord("\t"))
                ):
                    p += 1
                var v: Int = 0
                var saw: Bool = False
                while (
                    p < line_end
                    and buf[p] >= UInt8(ord("0"))
                    and buf[p] <= UInt8(ord("9"))
                ):
                    v = v * 10 + Int((buf[p] - UInt8(ord("0"))).cast[DType.int32]())
                    p += 1
                    saw = True
                if saw:
                    return v
                return -1
        i = nl + 1
    return -1


def parse_request(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin], n: Int
) -> Tuple[Int, Int, Int, Int]:
    if n < 16:
        return (REQ_INCOMPLETE, 0, 0, 0)

    if starts_with(buf, n, "POST /fraud-score"):
        var hdr_end = find_crlf2(buf, n)
        if hdr_end < 0:
            return (REQ_INCOMPLETE, 0, 0, 0)
        var cl = parse_content_length(buf, hdr_end + 2)
        if cl < 0:
            return (REQ_BAD, 0, 0, 0)
        var body_start = hdr_end + 4
        var total = body_start + cl
        if n < total:
            return (REQ_INCOMPLETE, 0, 0, 0)
        return (REQ_POST_SCORE, body_start, cl, total)

    if starts_with(buf, n, "GET /ready"):
        var sep = find_crlf2(buf, n)
        if sep < 0:
            return (REQ_INCOMPLETE, 0, 0, 0)
        return (REQ_GET_READY, 0, 0, sep + 4)

    var sep = find_crlf2(buf, n)
    if sep < 0:
        return (REQ_INCOMPLETE, 0, 0, 0)
    return (REQ_OTHER, 0, 0, sep + 4)


def respond(
    idx: Index,
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    body_start: Int,
    body_len: Int,
    kind: Int,
) -> StaticString:
    if kind == REQ_GET_READY:
        return READY_RESP
    if kind == REQ_OTHER:
        return NOT_FOUND_RESP

    # Heap-backed scratch for the Payload's known-merchant slots. InlineArray
    # storage gets writes elided by Mojo b1 codegen when later read through
    # unsafe_ptr()/FFI, which silently corrupted the known-merchant feature
    # and caused the 1 FN observed in the contest.
    var known_ptrs = libc_malloc(KNOWN_PTRS_BYTES)
    var known_lens = libc_malloc(KNOWN_LENS_BYTES)
    var parsed = parse(buf + body_start, body_len, known_ptrs, known_lens)
    if not parsed[0]:
        libc_free(known_ptrs)
        libc_free(known_lens)
        return SCORE_0
    var payload = parsed[1]
    var v_raw = libc_malloc(DIMS * 4)
    var v_ptr = v_raw.bitcast[Float32]()
    vectorize(payload, v_ptr)
    var frauds = score(idx, v_ptr)
    libc_free(v_raw)
    libc_free(known_ptrs)
    libc_free(known_lens)
    return score_resp(frauds)
