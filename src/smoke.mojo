"""
Mojo 1.0.0b1 sanity test: exercises the SIMD kernel against the live
Mojo compiler that's actually installed on the host.

Verifies:
- SIMD[DType.int16, 16] arithmetic and reduction.
- Pair-pack bitcast trick (int32 splat -> int16x16) for 8-lane distance.
- bbox_lower_bound using lane-wise max + reduce_add.
- libc malloc/free via @extern abi("c").

Run:
    mojo build src/smoke.mojo -o smoke && ./smoke
Expected output:
    block dist lane0 = 56  (= 14 dims * (2^2))
    bbox lb = 56
"""

from std.memory import UnsafePointer, bitcast


@extern("malloc")
def libc_malloc(n: Int) abi("c") -> UnsafePointer[UInt8, origin=MutExternalOrigin]:
    ...


@extern("free")
def libc_free(p: UnsafePointer[UInt8, origin=MutExternalOrigin]) abi("c"):
    ...


comptime LANES: Int = 8
comptime DIMS: Int = 14
comptime PADDED_DIMS: Int = 16


def _pair_madd(d: SIMD[DType.int16, 16]) -> SIMD[DType.int64, LANES]:
    var d32 = d.cast[DType.int32]()
    var sq = d32 * d32
    var pair = SIMD[DType.int32, LANES](0)
    comptime for lane in range(LANES):
        pair[lane] = sq[lane * 2] + sq[lane * 2 + 1]
    return pair.cast[DType.int64]()


def blk_dist(
    vectors: UnsafePointer[Int16, origin=MutExternalOrigin],
    q: UnsafePointer[Int16, origin=MutExternalOrigin],
) -> SIMD[DType.int64, 8]:
    """One IVF block (8 lanes) distance, pair-packed (v11 madd path)."""
    var acc = SIMD[DType.int64, LANES](0)

    comptime for p in range(7):
        var pair_lo: Int32 = Int32(q[p * 2]) & 0xFFFF
        var pair_hi: Int32 = Int32(q[p * 2 + 1]) << 16
        var q_pair_int: Int32 = pair_lo | pair_hi
        var q32 = SIMD[DType.int32, LANES](q_pair_int)
        var q_pair = bitcast[DType.int16, 16](q32)
        var base = vectors + p * LANES * 2
        var block_v = base.load[width=16]()
        var d = q_pair - block_v
        acc = acc + _pair_madd(d)
    return acc


def bbox_lower_bound(
    q: UnsafePointer[Int16, origin=MutExternalOrigin],
    mn: UnsafePointer[Int16, origin=MutExternalOrigin],
    mx: UnsafePointer[Int16, origin=MutExternalOrigin],
) -> Int64:
    var qv = q.load[width=16]()
    var mnv = mn.load[width=16]()
    var mxv = mx.load[width=16]()
    var zero = SIMD[DType.int16, 16](0)
    var below = max(mnv - qv, zero)
    var above = max(qv - mxv, zero)
    var gap = max(below, above)
    var acc: Int64 = 0

    comptime for i in range(16):
        var g: Int64 = Int64(gap[i])
        acc += g * g
    return acc


def main():
    var qraw = libc_malloc(PADDED_DIMS * 2)
    var vraw = libc_malloc(PADDED_DIMS * LANES * 2)
    var q = qraw.bitcast[Int16]()
    var v = vraw.bitcast[Int16]()

    comptime for i in range(PADDED_DIMS):
        q[i] = 0

    comptime for p in range(7):
        comptime for lane in range(LANES):
            var d0_index = p * LANES * 2 + lane * 2 + 0
            var d1_index = p * LANES * 2 + lane * 2 + 1
            var dim0 = p * 2
            var dim1 = p * 2 + 1
            v[d0_index] = 2 if dim0 < DIMS else 0
            v[d1_index] = 2 if dim1 < DIMS else 0

    var d = blk_dist(v, q)
    print("block dist lane0 =", Int(d[0]))
    print("block dist lane7 =", Int(d[7]))

    var mnraw = libc_malloc(PADDED_DIMS * 2)
    var mxraw = libc_malloc(PADDED_DIMS * 2)
    var mn = mnraw.bitcast[Int16]()
    var mx = mxraw.bitcast[Int16]()

    comptime for i in range(DIMS):
        mn[i] = 2
        mx[i] = 5

    comptime for i in range(DIMS, PADDED_DIMS):
        mn[i] = 0
        mx[i] = 0
    var lb = bbox_lower_bound(q, mn, mx)
    print("bbox lb =", Int(lb))

    libc_free(qraw)
    libc_free(vraw)
    libc_free(mnraw)
    libc_free(mxraw)
