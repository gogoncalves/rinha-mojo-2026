"""
Feature vector normalization: Payload -> 14-dim float32 vector.

Replicates Zig v31 normalize.zig exactly:
- 14 dims, 16 padded (SIMD-friendly)
- MCC risk via fast 4-byte packed hash
- has_last gating uses sentinel -1.0 (caller expected to handle)
- All clamps in [0, 1]
"""

from std.memory import UnsafePointer
from time_utils import Stamp, parse_ts, epoch_seconds, day_of_week
from json_parse import Payload, MAX_KNOWN

comptime DIMS: Int = 14
comptime PADDED_DIMS: Int = 16

comptime MAX_AMOUNT: Float32 = 10_000.0
comptime MAX_INSTALLMENTS: Float32 = 12.0
comptime AMOUNT_VS_AVG_RATIO: Float32 = 10.0
comptime MAX_MINUTES: Float32 = 1440.0
comptime MAX_KM: Float32 = 1000.0
comptime MAX_TX_COUNT_24H: Float32 = 20.0
comptime MAX_MERCHANT_AVG_AMOUNT: Float32 = 10_000.0


@always_inline
def pack4(s0: UInt8, s1: UInt8, s2: UInt8, s3: UInt8) -> UInt32:
    return (
        (s0.cast[DType.uint32]() << 24)
        | (s1.cast[DType.uint32]() << 16)
        | (s2.cast[DType.uint32]() << 8)
        | s3.cast[DType.uint32]()
    )


@always_inline
def pack_lit(s: StaticString) -> UInt32:
    return (
        (UInt32(ord(s[byte=0])) << 24)
        | (UInt32(ord(s[byte=1])) << 16)
        | (UInt32(ord(s[byte=2])) << 8)
        | UInt32(ord(s[byte=3]))
    )


def mcc_risk(
    mcc_ptr: UnsafePointer[UInt8, origin=MutExternalOrigin],
    mcc_len: Int,
) -> Float32:
    if mcc_len != 4:
        return 0.5
    var x = pack4(mcc_ptr[0], mcc_ptr[1], mcc_ptr[2], mcc_ptr[3])
    if x == pack_lit("5411"):
        return 0.15
    if x == pack_lit("5812"):
        return 0.30
    if x == pack_lit("5912"):
        return 0.20
    if x == pack_lit("5944"):
        return 0.45
    if x == pack_lit("7801"):
        return 0.80
    if x == pack_lit("7802"):
        return 0.75
    if x == pack_lit("7995"):
        return 0.85
    if x == pack_lit("4511"):
        return 0.35
    if x == pack_lit("5311"):
        return 0.25
    if x == pack_lit("5999"):
        return 0.50
    return 0.5


@always_inline
def clamp01(x: Float32) -> Float32:
    if x < 0.0:
        return 0.0
    if x > 1.0:
        return 1.0
    return x


@always_inline
def bytes_eq(
    a: UnsafePointer[UInt8, origin=MutExternalOrigin], a_len: Int,
    b: UnsafePointer[UInt8, origin=MutExternalOrigin], b_len: Int,
) -> Bool:
    if a_len != b_len:
        return False
    for i in range(a_len):
        if a[i] != b[i]:
            return False
    return True


def vectorize(
    p: Payload,
    output: UnsafePointer[Float32, origin=MutExternalOrigin],
):
    """Writes DIMS=14 floats into output[0..14]."""
    var ts = parse_ts(p.requested_at_ptr)
    var cur = epoch_seconds(ts)
    var dow = day_of_week(ts.year, ts.month, ts.day)

    var known: Bool = False
    var i: Int = 0
    var ptr_arr = p.known_merchants_ptr.bitcast[
        UnsafePointer[UInt8, origin=MutExternalOrigin]
    ]()
    var len_arr = p.known_merchants_len.bitcast[UInt16]()
    while i < Int(p.known_n):
        var mp = ptr_arr[i]
        var ml = Int(len_arr[i])
        if bytes_eq(mp, ml, p.merchant_id_ptr, p.merchant_id_len):
            known = True
            break
        i += 1

    var d5: Float32 = -1.0
    var d6: Float32 = -1.0
    if p.has_last:
        var lts = parse_ts(p.last_timestamp_ptr)
        var last = epoch_seconds(lts)
        var diff_secs = cur - last
        var mins_raw: Float32 = Float32(diff_secs) / 60.0
        var mins: Float32 = mins_raw
        if mins_raw < 0.0:
            mins = 0.0
        d5 = clamp01(mins / MAX_MINUTES)
        d6 = clamp01(p.last_km_from_current / MAX_KM)

    output[0] = clamp01(p.amount / MAX_AMOUNT)
    output[1] = clamp01(Float32(p.installments) / MAX_INSTALLMENTS)
    output[2] = clamp01((p.amount / p.avg_amount) / AMOUNT_VS_AVG_RATIO)
    output[3] = Float32(ts.hour) / 23.0
    output[4] = Float32(dow) / 6.0
    output[5] = d5
    output[6] = d6
    output[7] = clamp01(p.km_from_home / MAX_KM)
    output[8] = clamp01(Float32(p.tx_count_24h) / MAX_TX_COUNT_24H)
    output[9] = 1.0 if p.is_online else 0.0
    output[10] = 1.0 if p.card_present else 0.0
    output[11] = 0.0 if known else 1.0
    output[12] = mcc_risk(p.mcc_ptr, p.mcc_len)
    output[13] = clamp01(p.merchant_avg_amount / MAX_MERCHANT_AVG_AMOUNT)
