"""
Minimal hand-rolled JSON parser for the fraud-score payload schema.
Replicates Zig v31 json.zig.

Payload structure (top-level keys we care about):
- transaction: { amount, installments, requested_at }
- customer: { avg_amount, tx_count_24h, known_merchants[] }
- merchant: { id, mcc, avg_amount }
- terminal: { is_online, card_present, km_from_home }
- last_transaction: null | { timestamp, km_from_current }

No allocations. All slices are pointers into the request buffer.
"""

from std.memory import UnsafePointer


comptime MAX_KNOWN: Int = 16
comptime KNOWN_PTRS_BYTES: Int = MAX_KNOWN * 8
comptime KNOWN_LENS_BYTES: Int = MAX_KNOWN * 2


struct Payload(Copyable, Movable, ImplicitlyCopyable):
    var amount: Float32
    var installments: UInt32
    var requested_at_ptr: UnsafePointer[UInt8, origin=MutExternalOrigin]

    var avg_amount: Float32
    var tx_count_24h: UInt32

    # NOTE: known_merchants arrays are heap-backed via libc_malloc instead
    # of InlineArray. Mojo b1 codegen elides writes to InlineArray storage
    # when the array is later read through unsafe_ptr()/FFI, which broke
    # the known-merchant check (always missed -> output[11]=1.0 always) and
    # caused the 1 FN at scale.
    var known_merchants_ptr: UnsafePointer[UInt8, origin=MutExternalOrigin]
    var known_merchants_len: UnsafePointer[UInt8, origin=MutExternalOrigin]
    var known_n: UInt32

    var merchant_id_ptr: UnsafePointer[UInt8, origin=MutExternalOrigin]
    var merchant_id_len: Int
    var mcc_ptr: UnsafePointer[UInt8, origin=MutExternalOrigin]
    var mcc_len: Int
    var merchant_avg_amount: Float32

    var is_online: Bool
    var card_present: Bool
    var km_from_home: Float32

    var has_last: Bool
    var last_timestamp_ptr: UnsafePointer[UInt8, origin=MutExternalOrigin]
    var last_km_from_current: Float32

    def __init__(out self):
        self.amount = 0.0
        self.installments = 0
        self.requested_at_ptr = UnsafePointer[
            UInt8, origin=MutExternalOrigin
        ].unsafe_dangling()
        self.avg_amount = 1.0
        self.tx_count_24h = 0
        self.known_merchants_ptr = UnsafePointer[
            UInt8, origin=MutExternalOrigin
        ].unsafe_dangling()
        self.known_merchants_len = UnsafePointer[
            UInt8, origin=MutExternalOrigin
        ].unsafe_dangling()
        self.known_n = 0
        self.merchant_id_ptr = UnsafePointer[
            UInt8, origin=MutExternalOrigin
        ].unsafe_dangling()
        self.merchant_id_len = 0
        self.mcc_ptr = UnsafePointer[
            UInt8, origin=MutExternalOrigin
        ].unsafe_dangling()
        self.mcc_len = 0
        self.merchant_avg_amount = 0.0
        self.is_online = False
        self.card_present = False
        self.km_from_home = 0.0
        self.has_last = False
        self.last_timestamp_ptr = UnsafePointer[
            UInt8, origin=MutExternalOrigin
        ].unsafe_dangling()
        self.last_km_from_current = 0.0



@always_inline
def is_ws(c: UInt8) -> Bool:
    return c == UInt8(ord(" ")) or c == UInt8(ord("\t")) or c == UInt8(ord("\r")) or c == UInt8(ord("\n"))


@always_inline
def skip_ws(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
):
    while i < n and is_ws(buf[i]):
        i += 1


@always_inline
def key_eq(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    start: Int,
    end: Int,
    lit: StaticString,
) -> Bool:
    var k_len = end - start
    if k_len != lit.byte_length():
        return False
    for j in range(k_len):
        if buf[start + j] != UInt8(ord(lit[byte=j])):
            return False
    return True


def read_key(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
) -> Tuple[Int, Int]:
    skip_ws(buf, n, i)
    if i >= n or buf[i] != UInt8(ord('"')):
        return (-1, -1)
    i += 1
    var start = i
    while i < n and buf[i] != UInt8(ord('"')):
        i += 1
    if i >= n:
        return (-1, -1)
    var end = i
    i += 1
    return (start, end)


def read_string(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
) -> Tuple[Int, Int]:
    skip_ws(buf, n, i)
    if i >= n or buf[i] != UInt8(ord('"')):
        return (-1, -1)
    i += 1
    var start = i
    while i < n and buf[i] != UInt8(ord('"')):
        i += 1
    if i >= n:
        return (-1, -1)
    var end = i
    i += 1
    return (start, end)


def read_u32(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
) -> UInt32:
    skip_ws(buf, n, i)
    var v: UInt32 = 0
    while i < n:
        var c = buf[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            break
        v = v * 10 + (c - UInt8(ord("0"))).cast[DType.uint32]()
        i += 1
    return v


def read_f32(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
) -> Float32:
    skip_ws(buf, n, i)
    var neg: Bool = False
    if i < n and buf[i] == UInt8(ord("-")):
        neg = True
        i += 1
    elif i < n and buf[i] == UInt8(ord("+")):
        i += 1
    var int_part: Float64 = 0.0
    while i < n:
        var c = buf[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            break
        int_part = int_part * 10.0 + Float64(
            Int((c - UInt8(ord("0"))).cast[DType.int32]())
        )
        i += 1
    var frac: Float64 = 0.0
    var frac_div: Float64 = 1.0
    if i < n and buf[i] == UInt8(ord(".")):
        i += 1
        while i < n:
            var c = buf[i]
            if c < UInt8(ord("0")) or c > UInt8(ord("9")):
                break
            frac = frac * 10.0 + Float64(
                Int((c - UInt8(ord("0"))).cast[DType.int32]())
            )
            frac_div = frac_div * 10.0
            i += 1
    var v: Float64 = int_part + frac / frac_div
    if i < n and (buf[i] == UInt8(ord("e")) or buf[i] == UInt8(ord("E"))):
        i += 1
        var esign: Int = 1
        if i < n and buf[i] == UInt8(ord("-")):
            esign = -1
            i += 1
        elif i < n and buf[i] == UInt8(ord("+")):
            i += 1
        var exp: Int = 0
        while i < n:
            var c = buf[i]
            if c < UInt8(ord("0")) or c > UInt8(ord("9")):
                break
            exp = exp * 10 + Int((c - UInt8(ord("0"))).cast[DType.int32]())
            i += 1
        var mult: Float64 = 1.0
        for _ in range(exp):
            mult = mult * 10.0
        if esign < 0:
            v = v / mult
        else:
            v = v * mult
    if neg:
        v = -v
    return v.cast[DType.float32]()


def read_bool(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
) -> Bool:
    skip_ws(buf, n, i)
    if (
        i + 4 <= n
        and buf[i] == UInt8(ord("t"))
        and buf[i + 1] == UInt8(ord("r"))
        and buf[i + 2] == UInt8(ord("u"))
        and buf[i + 3] == UInt8(ord("e"))
    ):
        i += 4
        return True
    if i + 5 <= n and buf[i] == UInt8(ord("f")):
        i += 5
        return False
    return False


def skip_value(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
):
    skip_ws(buf, n, i)
    if i >= n:
        return
    var c = buf[i]
    if c == UInt8(ord('"')):
        i += 1
        while i < n and buf[i] != UInt8(ord('"')):
            i += 1
        if i < n:
            i += 1
        return
    if c == UInt8(ord("{")) or c == UInt8(ord("[")):
        var close: UInt8 = UInt8(ord("}")) if c == UInt8(ord("{")) else UInt8(ord("]"))
        var depth: Int = 1
        i += 1
        while i < n and depth > 0:
            if buf[i] == c:
                depth += 1
            elif buf[i] == close:
                depth -= 1
            i += 1
        return
    while i < n:
        var cc = buf[i]
        if cc == UInt8(ord(",")) or cc == UInt8(ord("}")) or cc == UInt8(ord("]")):
            return
        i += 1



def parse_tx(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
    mut p: Payload,
) -> Bool:
    skip_ws(buf, n, i)
    if i >= n or buf[i] != UInt8(ord("{")):
        return False
    i += 1
    while True:
        skip_ws(buf, n, i)
        if i >= n:
            return False
        if buf[i] == UInt8(ord("}")):
            i += 1
            return True
        var k = read_key(buf, n, i)
        if k[0] < 0:
            return False
        skip_ws(buf, n, i)
        if i >= n or buf[i] != UInt8(ord(":")):
            return False
        i += 1
        if key_eq(buf, k[0], k[1], "amount"):
            p.amount = read_f32(buf, n, i)
        elif key_eq(buf, k[0], k[1], "installments"):
            p.installments = read_u32(buf, n, i)
        elif key_eq(buf, k[0], k[1], "requested_at"):
            var s = read_string(buf, n, i)
            if s[0] < 0:
                return False
            p.requested_at_ptr = buf + s[0]
        else:
            skip_value(buf, n, i)
        skip_ws(buf, n, i)
        if i < n and buf[i] == UInt8(ord(",")):
            i += 1


def parse_cust(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
    mut p: Payload,
) -> Bool:
    skip_ws(buf, n, i)
    if i >= n or buf[i] != UInt8(ord("{")):
        return False
    i += 1
    while True:
        skip_ws(buf, n, i)
        if i >= n:
            return False
        if buf[i] == UInt8(ord("}")):
            i += 1
            return True
        var k = read_key(buf, n, i)
        if k[0] < 0:
            return False
        skip_ws(buf, n, i)
        if i >= n or buf[i] != UInt8(ord(":")):
            return False
        i += 1
        if key_eq(buf, k[0], k[1], "avg_amount"):
            p.avg_amount = read_f32(buf, n, i)
        elif key_eq(buf, k[0], k[1], "tx_count_24h"):
            p.tx_count_24h = read_u32(buf, n, i)
        elif key_eq(buf, k[0], k[1], "known_merchants"):
            skip_ws(buf, n, i)
            if i >= n or buf[i] != UInt8(ord("[")):
                return False
            i += 1
            p.known_n = 0
            var ptr_arr = p.known_merchants_ptr.bitcast[
                UnsafePointer[UInt8, origin=MutExternalOrigin]
            ]()
            var len_arr = p.known_merchants_len.bitcast[UInt16]()
            while True:
                skip_ws(buf, n, i)
                if i >= n:
                    return False
                if buf[i] == UInt8(ord("]")):
                    i += 1
                    break
                var s = read_string(buf, n, i)
                if s[0] < 0:
                    return False
                if Int(p.known_n) < MAX_KNOWN:
                    var idx = Int(p.known_n)
                    ptr_arr[idx] = buf + s[0]
                    len_arr[idx] = UInt16(s[1] - s[0])
                    p.known_n += 1
                skip_ws(buf, n, i)
                if i < n and buf[i] == UInt8(ord(",")):
                    i += 1
        else:
            skip_value(buf, n, i)
        skip_ws(buf, n, i)
        if i < n and buf[i] == UInt8(ord(",")):
            i += 1


def parse_mer(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
    mut p: Payload,
) -> Bool:
    skip_ws(buf, n, i)
    if i >= n or buf[i] != UInt8(ord("{")):
        return False
    i += 1
    while True:
        skip_ws(buf, n, i)
        if i >= n:
            return False
        if buf[i] == UInt8(ord("}")):
            i += 1
            return True
        var k = read_key(buf, n, i)
        if k[0] < 0:
            return False
        skip_ws(buf, n, i)
        if i >= n or buf[i] != UInt8(ord(":")):
            return False
        i += 1
        if key_eq(buf, k[0], k[1], "id"):
            var s = read_string(buf, n, i)
            if s[0] < 0:
                return False
            p.merchant_id_ptr = buf + s[0]
            p.merchant_id_len = s[1] - s[0]
        elif key_eq(buf, k[0], k[1], "mcc"):
            var s = read_string(buf, n, i)
            if s[0] < 0:
                return False
            p.mcc_ptr = buf + s[0]
            p.mcc_len = s[1] - s[0]
        elif key_eq(buf, k[0], k[1], "avg_amount"):
            p.merchant_avg_amount = read_f32(buf, n, i)
        else:
            skip_value(buf, n, i)
        skip_ws(buf, n, i)
        if i < n and buf[i] == UInt8(ord(",")):
            i += 1


def parse_term(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
    mut p: Payload,
) -> Bool:
    skip_ws(buf, n, i)
    if i >= n or buf[i] != UInt8(ord("{")):
        return False
    i += 1
    while True:
        skip_ws(buf, n, i)
        if i >= n:
            return False
        if buf[i] == UInt8(ord("}")):
            i += 1
            return True
        var k = read_key(buf, n, i)
        if k[0] < 0:
            return False
        skip_ws(buf, n, i)
        if i >= n or buf[i] != UInt8(ord(":")):
            return False
        i += 1
        if key_eq(buf, k[0], k[1], "is_online"):
            p.is_online = read_bool(buf, n, i)
        elif key_eq(buf, k[0], k[1], "card_present"):
            p.card_present = read_bool(buf, n, i)
        elif key_eq(buf, k[0], k[1], "km_from_home"):
            p.km_from_home = read_f32(buf, n, i)
        else:
            skip_value(buf, n, i)
        skip_ws(buf, n, i)
        if i < n and buf[i] == UInt8(ord(",")):
            i += 1


def parse_last(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    mut i: Int,
    mut p: Payload,
) -> Bool:
    skip_ws(buf, n, i)
    if (
        i + 4 <= n
        and buf[i] == UInt8(ord("n"))
        and buf[i + 1] == UInt8(ord("u"))
        and buf[i + 2] == UInt8(ord("l"))
        and buf[i + 3] == UInt8(ord("l"))
    ):
        i += 4
        p.has_last = False
        return True
    if i >= n or buf[i] != UInt8(ord("{")):
        return False
    i += 1
    p.has_last = True
    while True:
        skip_ws(buf, n, i)
        if i >= n:
            return False
        if buf[i] == UInt8(ord("}")):
            i += 1
            return True
        var k = read_key(buf, n, i)
        if k[0] < 0:
            return False
        skip_ws(buf, n, i)
        if i >= n or buf[i] != UInt8(ord(":")):
            return False
        i += 1
        if key_eq(buf, k[0], k[1], "timestamp"):
            var s = read_string(buf, n, i)
            if s[0] < 0:
                return False
            p.last_timestamp_ptr = buf + s[0]
        elif key_eq(buf, k[0], k[1], "km_from_current"):
            p.last_km_from_current = read_f32(buf, n, i)
        else:
            skip_value(buf, n, i)
        skip_ws(buf, n, i)
        if i < n and buf[i] == UInt8(ord(",")):
            i += 1



def parse(
    buf: UnsafePointer[UInt8, origin=MutExternalOrigin],
    n: Int,
    known_ptrs: UnsafePointer[UInt8, origin=MutExternalOrigin],
    known_lens: UnsafePointer[UInt8, origin=MutExternalOrigin],
) -> Tuple[Bool, Payload]:
    var p = Payload()
    p.known_merchants_ptr = known_ptrs
    p.known_merchants_len = known_lens
    var i: Int = 0
    skip_ws(buf, n, i)
    if i >= n or buf[i] != UInt8(ord("{")):
        return (False, p)
    i += 1
    while True:
        skip_ws(buf, n, i)
        if i >= n:
            return (False, p)
        if buf[i] == UInt8(ord("}")):
            i += 1
            return (True, p)
        var k = read_key(buf, n, i)
        if k[0] < 0:
            return (False, p)
        skip_ws(buf, n, i)
        if i >= n or buf[i] != UInt8(ord(":")):
            return (False, p)
        i += 1
        if key_eq(buf, k[0], k[1], "transaction"):
            if not parse_tx(buf, n, i, p):
                return (False, p)
        elif key_eq(buf, k[0], k[1], "customer"):
            if not parse_cust(buf, n, i, p):
                return (False, p)
        elif key_eq(buf, k[0], k[1], "merchant"):
            if not parse_mer(buf, n, i, p):
                return (False, p)
        elif key_eq(buf, k[0], k[1], "terminal"):
            if not parse_term(buf, n, i, p):
                return (False, p)
        elif key_eq(buf, k[0], k[1], "last_transaction"):
            if not parse_last(buf, n, i, p):
                return (False, p)
        else:
            skip_value(buf, n, i)
        skip_ws(buf, n, i)
        if i < n and buf[i] == UInt8(ord(",")):
            i += 1
