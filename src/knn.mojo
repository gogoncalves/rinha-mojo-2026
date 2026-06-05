"""
KNN-5 with IVF, pair-packed SoA SIMD lanes.

v11: replaced the scalar `pa[lane] = a*a + b*b` lane-by-lane loop with a
fully vectorized madd-style reduction (`(d*d) -> pair-sum` via int32 cast),
so each pair's contribution to the 8-lane distance is ~3 SIMD ops instead
of 24 scalar 64-bit ops. Per-block distance accumulator stays in i64.

Replicates Zig v31 index.zig hot loop. Mojo-specific:
- SIMD[DType.int16, 16] is native, no @Vector ceremony.
- @always_inline lets us inline blk_dist into scan_cluster without LTO games.
- bitcast lets the pair-packing trick work as in Zig: load 8 lanes of
  int32 pair (lo|hi) reinterpret as 16 int16 contiguous so the
  subtraction `q_pair - block_v` is one SIMD op for all 8 lanes x 2 dims.

Quant model:
- DIMS=14 features, PADDED_DIMS=16 (last 2 dims = 0)
- SCALE=10000.0, i16 codes (range ~[-10000, 10000])
- Per-block distance accumulator stays in i64
"""

from std.memory import UnsafePointer, bitcast
from std.sys.intrinsics import prefetch, PrefetchOptions
from normalize import DIMS, PADDED_DIMS


comptime LANES: Int = 8
comptime PAIRS: Int = (DIMS + 1) // 2
comptime BLOCK_BYTES: Int = PADDED_DIMS * LANES * 2

comptime QUANT_SCALE: Float32 = 10000.0
comptime QUANT_MAX: Float32 = 10000.0

comptime NPROBE: Int = 2
comptime REPAIR_EXTRA: Int = 30
comptime MAX_PROBES: Int = NPROBE + REPAIR_EXTRA
comptime MAX_K: Int = 4096
comptime SEEN_WORDS: Int = (MAX_K + 63) // 64
comptime TOP_K: Int = 5
comptime REPAIR_MIN: UInt8 = 1
comptime REPAIR_MAX_FRAUDS: UInt8 = 4
comptime EARLY_DIST_FRAC: Int64 = 120

comptime EARLY_DIST: Int64 = (
    (Int64(10000) * EARLY_DIST_FRAC // 1000)
    * (Int64(10000) * EARLY_DIST_FRAC // 1000)
    * Int64(DIMS)
)

comptime I64_MAX: Int64 = 9223372036854775807


@always_inline
def quantize(
    v: UnsafePointer[Float32, origin=MutExternalOrigin],
    dst: UnsafePointer[Int16, origin=MutExternalOrigin],
):
    comptime for i in range(DIMS):
        var x = v[i] * QUANT_SCALE
        if x > QUANT_MAX:
            x = QUANT_MAX
        if x < -QUANT_MAX:
            x = -QUANT_MAX
        var r: Float32 = x + (Float32(0.5) if x >= 0.0 else Float32(-0.5))
        dst[i] = Int16(Int32(r))

    comptime for i in range(DIMS, PADDED_DIMS):
        dst[i] = 0


@always_inline
def _pair_madd(d: SIMD[DType.int16, 16]) -> SIMD[DType.int64, LANES]:
    """Pair-wise madd: returns [d[0]^2+d[1]^2, d[2]^2+d[3]^2, ..., d[14]^2+d[15]^2].

    We widen to int32 first so d*d does not overflow (|d| up to ~20000,
    d*d up to ~4e8 which exceeds int16 range). Then a single per-lane add
    folds pairs into 8 int32 lanes; final cast to int64 keeps the
    accumulator headroom intact (14-dim sum max ~5.6e9 > INT32_MAX).
    """
    var d32 = d.cast[DType.int32]()
    var sq = d32 * d32
    # sq has 16 int32 lanes: [a0,b0,a1,b1,...,a7,b7].
    # Bitcast to two int32x8 halves via int64x8 trick: each int64 lane
    # holds [aN | bN]. We instead just shuffle: even/odd pairs.
    # Use SIMD slicing helpers — `slice` is generic over offset.
    var pair: SIMD[DType.int32, LANES] = SIMD[DType.int32, LANES](0)
    comptime for lane in range(LANES):
        pair[lane] = sq[lane * 2] + sq[lane * 2 + 1]
    return pair.cast[DType.int64]()


@always_inline
def blk_dist(
    vectors: UnsafePointer[Int16, origin=MutExternalOrigin],
    block_idx: Int,
    q: UnsafePointer[Int16, origin=MutExternalOrigin],
) -> SIMD[DType.int64, LANES]:
    var block_off = block_idx * PADDED_DIMS * LANES
    var acc0 = SIMD[DType.int64, LANES](0)
    var acc1 = SIMD[DType.int64, LANES](0)

    comptime for p in range(PAIRS):
        var pair_lo: Int32 = Int32(q[p * 2]) & 0xFFFF
        var pair_hi: Int32 = Int32(q[p * 2 + 1]) << 16
        var q_pair_int: Int32 = pair_lo | pair_hi

        var q32 = SIMD[DType.int32, LANES](q_pair_int)
        var q_pair = bitcast[DType.int16, 16](q32)

        var base = vectors + (block_off + p * LANES * 2)
        var block_v = base.load[width=16]()

        var d = q_pair - block_v
        var pa = _pair_madd(d)

        if (p & 1) == 0:
            acc0 = acc0 + pa
        else:
            acc1 = acc1 + pa

    return acc0 + acc1


@always_inline
def blk_dist_prune(
    vectors: UnsafePointer[Int16, origin=MutExternalOrigin],
    block_idx: Int,
    q: UnsafePointer[Int16, origin=MutExternalOrigin],
    threshold: Int64,
) -> Tuple[SIMD[DType.int64, LANES], Bool]:
    var block_off = block_idx * PADDED_DIMS * LANES
    var acc0 = SIMD[DType.int64, LANES](0)
    var acc1 = SIMD[DType.int64, LANES](0)

    comptime for p in range(PAIRS):
        var pair_lo: Int32 = Int32(q[p * 2]) & 0xFFFF
        var pair_hi: Int32 = Int32(q[p * 2 + 1]) << 16
        var q_pair_int: Int32 = pair_lo | pair_hi
        var q32 = SIMD[DType.int32, LANES](q_pair_int)
        var q_pair = bitcast[DType.int16, 16](q32)

        var base = vectors + (block_off + p * LANES * 2)
        var block_v = base.load[width=16]()

        var d = q_pair - block_v
        var pa = _pair_madd(d)

        if (p & 1) == 0:
            acc0 = acc0 + pa
        else:
            acc1 = acc1 + pa

        comptime if p == 2 or p == 4:
            var partial = acc0 + acc1
            var t = SIMD[DType.int64, LANES](threshold)
            var exceeds = partial.ge(t)
            if exceeds.reduce_and():
                return (partial, True)

    return (acc0 + acc1, False)


@always_inline
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


@always_inline
def insert_best(
    dist: Int64,
    label: UInt8,
    best_d: UnsafePointer[Int64, origin=MutExternalOrigin],
    best_l: UnsafePointer[UInt8, origin=MutExternalOrigin],
):
    if dist >= best_d[TOP_K - 1]:
        return
    var pos: Int = TOP_K - 1
    while pos > 0 and dist < best_d[pos - 1]:
        best_d[pos] = best_d[pos - 1]
        best_l[pos] = best_l[pos - 1]
        pos -= 1
    best_d[pos] = dist
    best_l[pos] = label



@always_inline
def heap_sift_up(
    probes_c: UnsafePointer[UInt32, origin=MutExternalOrigin],
    probes_d: UnsafePointer[Int64, origin=MutExternalOrigin],
    start: Int,
):
    var i = start
    while i > 0:
        var parent = (i - 1) // 2
        if probes_d[i] > probes_d[parent]:
            var tc = probes_c[i]
            var td = probes_d[i]
            probes_c[i] = probes_c[parent]
            probes_d[i] = probes_d[parent]
            probes_c[parent] = tc
            probes_d[parent] = td
            i = parent
        else:
            return


@always_inline
def heap_sift_down(
    probes_c: UnsafePointer[UInt32, origin=MutExternalOrigin],
    probes_d: UnsafePointer[Int64, origin=MutExternalOrigin],
    start: Int,
    size: Int,
):
    var i = start
    while True:
        var left = 2 * i + 1
        var right = 2 * i + 2
        var largest = i
        if left < size and probes_d[left] > probes_d[largest]:
            largest = left
        if right < size and probes_d[right] > probes_d[largest]:
            largest = right
        if largest == i:
            return
        var tc = probes_c[i]
        var td = probes_d[i]
        probes_c[i] = probes_c[largest]
        probes_d[i] = probes_d[largest]
        probes_c[largest] = tc
        probes_d[largest] = td
        i = largest


@always_inline
def insert_probe(
    probes_c: UnsafePointer[UInt32, origin=MutExternalOrigin],
    probes_d: UnsafePointer[Int64, origin=MutExternalOrigin],
    mut count: Int,
    cluster: UInt32,
    dist: Int64,
):
    if count < MAX_PROBES:
        probes_c[count] = cluster
        probes_d[count] = dist
        heap_sift_up(probes_c, probes_d, count)
        count += 1
        return
    if dist >= probes_d[0]:
        return
    probes_c[0] = cluster
    probes_d[0] = dist
    heap_sift_down(probes_c, probes_d, 0, MAX_PROBES)


def heap_to_sorted(
    probes_c: UnsafePointer[UInt32, origin=MutExternalOrigin],
    probes_d: UnsafePointer[Int64, origin=MutExternalOrigin],
    count: Int,
):
    var n = count
    while n > 1:
        n -= 1
        var tc = probes_c[0]
        var td = probes_d[0]
        probes_c[0] = probes_c[n]
        probes_d[0] = probes_d[n]
        probes_c[n] = tc
        probes_d[n] = td
        heap_sift_down(probes_c, probes_d, 0, n)
