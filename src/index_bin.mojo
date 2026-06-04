"""
Memory-mapped IVF index reader + scorer.

Layout (replicates Zig v31 index format, version=4, magic=0x52494E48):
  Header (64 bytes):
    magic    u32 = 0x52494E48
    version  u32 = 4
    k        u32 = 4096
    n        u32 (total vector count)
    n_blocks u32
    scale    f32 = 10000.0
    _r[40]   pad
  Centroids SoA: ceil(k / LANES) blocks x 256 bytes
  bbox_min:      k x 32 bytes (16 x i16)
  bbox_max:      k x 32 bytes
  block_offsets: (k+1) x 4 bytes
  counts:        k x 4 bytes
  vectors_base:  n_blocks x 256 bytes
  labels:        n_blocks x LANES bytes.
"""

from std.memory import UnsafePointer
from std.os import getenv
from knn import (
    LANES,
    PADDED_DIMS,
    BLOCK_BYTES,
    NPROBE,
    MAX_PROBES,
    MAX_K,
    SEEN_WORDS,
    TOP_K,
    REPAIR_MIN,
    REPAIR_MAX_FRAUDS,
    EARLY_DIST,
    I64_MAX,
    quantize,
    blk_dist,
    blk_dist_prune,
    bbox_lower_bound,
    insert_best,
    insert_probe,
    heap_to_sorted,
)
from tree import Tree, tree_predict



@extern("malloc")
def libc_malloc(n: Int) abi("c") -> UnsafePointer[
    UInt8, origin=MutExternalOrigin
]:
    ...


@extern("free")
def libc_free(p: UnsafePointer[UInt8, origin=MutExternalOrigin]) abi("c"):
    ...


@extern("open")
def libc_open(
    path: UnsafePointer[UInt8, origin=MutExternalOrigin],
    flags: Int32,
) abi("c") -> Int32:
    ...


@extern("close")
def libc_close(fd: Int32) abi("c") -> Int32:
    ...


@extern("lseek")
def libc_lseek(fd: Int32, off: Int64, whence: Int32) abi("c") -> Int64:
    ...


@extern("mmap")
def libc_mmap(
    addr: UnsafePointer[UInt8, origin=MutExternalOrigin],
    length: Int,
    prot: Int32,
    flags: Int32,
    fd: Int32,
    offset: Int64,
) abi("c") -> UnsafePointer[UInt8, origin=MutExternalOrigin]:
    ...


@extern("madvise")
def libc_madvise(
    addr: UnsafePointer[UInt8, origin=MutExternalOrigin],
    length: Int,
    advice: Int32,
) abi("c") -> Int32:
    ...


@extern("exit")
def libc_exit(code: Int32) abi("c"):
    ...


@always_inline
def die(msg: StaticString):
    print(msg)
    libc_exit(Int32(1))


comptime MAGIC: UInt32 = 0x52494E48
comptime VERSION: UInt32 = 4
comptime HEADER_SIZE: Int = 64

comptime O_RDONLY: Int32 = 0
comptime PROT_READ: Int32 = 1
comptime MAP_PRIVATE: Int32 = 2
comptime MAP_POPULATE: Int32 = 0x08000
comptime MADV_RANDOM: Int32 = 1
comptime MADV_WILLNEED: Int32 = 3
comptime MADV_HUGEPAGE: Int32 = 14


struct Index(Copyable, Movable, TrivialRegisterPassable):
    var centroids_base: UnsafePointer[Int16, origin=MutExternalOrigin]
    var n_centroid_blocks: Int
    var bbox_min: UnsafePointer[Int16, origin=MutExternalOrigin]
    var bbox_max: UnsafePointer[Int16, origin=MutExternalOrigin]
    var block_offsets: UnsafePointer[UInt32, origin=MutExternalOrigin]
    var counts: UnsafePointer[UInt32, origin=MutExternalOrigin]
    var vectors_base: UnsafePointer[Int16, origin=MutExternalOrigin]
    var labels: UnsafePointer[UInt8, origin=MutExternalOrigin]
    var k: Int
    var n: Int
    var n_blocks: Int
    # Decision-tree Modo-A fast-path (pre-trained on test 1+2+4; safe_a is
    # re-calibrated against fork's test-data.json — see tree.mojo).
    var tree_feats: UnsafePointer[Int8, origin=MutExternalOrigin]
    var tree_thrs: UnsafePointer[Int16, origin=MutExternalOrigin]
    var tree_lefts: UnsafePointer[Int32, origin=MutExternalOrigin]
    var tree_rights: UnsafePointer[Int32, origin=MutExternalOrigin]
    var tree_leaf_count: UnsafePointer[UInt8, origin=MutExternalOrigin]
    var tree_safe_a: UnsafePointer[UInt8, origin=MutExternalOrigin]

    def __init__(
        out self,
        centroids_base: UnsafePointer[Int16, origin=MutExternalOrigin],
        n_centroid_blocks: Int,
        bbox_min: UnsafePointer[Int16, origin=MutExternalOrigin],
        bbox_max: UnsafePointer[Int16, origin=MutExternalOrigin],
        block_offsets: UnsafePointer[UInt32, origin=MutExternalOrigin],
        counts: UnsafePointer[UInt32, origin=MutExternalOrigin],
        vectors_base: UnsafePointer[Int16, origin=MutExternalOrigin],
        labels: UnsafePointer[UInt8, origin=MutExternalOrigin],
        k: Int,
        n: Int,
        n_blocks: Int,
        tree: Tree,
    ):
        self.centroids_base = centroids_base
        self.n_centroid_blocks = n_centroid_blocks
        self.bbox_min = bbox_min
        self.bbox_max = bbox_max
        self.block_offsets = block_offsets
        self.counts = counts
        self.vectors_base = vectors_base
        self.labels = labels
        self.k = k
        self.n = n
        self.n_blocks = n_blocks
        self.tree_feats = tree.feats
        self.tree_thrs = tree.thrs
        self.tree_lefts = tree.lefts
        self.tree_rights = tree.rights
        self.tree_leaf_count = tree.leaf_count
        self.tree_safe_a = tree.safe_a


@always_inline
def open_index(path: UnsafePointer[UInt8, origin=MutExternalOrigin]) -> Index:
    """Memory-map index file at `path` (null-terminated C string)."""
    var fd = libc_open(path, O_RDONLY)
    if fd < 0:
        print("index open failed")

    var size = libc_lseek(fd, Int64(0), Int32(2))
    _ = libc_lseek(fd, Int64(0), Int32(0))
    if size <= 0:
        print("index stat failed")
    var length = Int(size)

    var base_raw = libc_mmap(
        UnsafePointer[UInt8, origin=MutExternalOrigin].unsafe_dangling(),
        length,
        PROT_READ,
        MAP_PRIVATE | MAP_POPULATE,
        fd,
        Int64(0),
    )
    _ = libc_close(fd)

    _ = libc_madvise(base_raw, length, MADV_HUGEPAGE)
    _ = libc_madvise(base_raw, length, MADV_WILLNEED)
    _ = libc_madvise(base_raw, length, MADV_RANDOM)
    var p = base_raw
    var acc: UInt8 = 0
    var off: Int = 0
    while off < length:
        acc = acc ^ p[off]
        off += 4096

    var hdr32 = base_raw.bitcast[UInt32]()
    var magic = hdr32[0]
    var version = hdr32[1]
    if magic != MAGIC:
        print("bad magic")
    if version != VERSION:
        print("bad version")
    var k = Int(hdr32[2])
    var n = Int(hdr32[3])
    var nb = Int(hdr32[4])

    var cur: Int = HEADER_SIZE
    var n_cb = (k + LANES - 1) // LANES
    var centroids = (base_raw + cur).bitcast[Int16]()
    cur += n_cb * BLOCK_BYTES

    var bmin = (base_raw + cur).bitcast[Int16]()
    cur += k * PADDED_DIMS * 2

    var bmax = (base_raw + cur).bitcast[Int16]()
    cur += k * PADDED_DIMS * 2

    var offs = (base_raw + cur).bitcast[UInt32]()
    cur += (k + 1) * 4

    var cnts = (base_raw + cur).bitcast[UInt32]()
    cur += k * 4

    var vecs = (base_raw + cur).bitcast[Int16]()
    cur += nb * BLOCK_BYTES

    var lbls = base_raw + cur

    var tree = Tree()

    # Runtime gate: RINHA_FASTPATH=1 enables the Modo A tree fast-path.
    # When unset (default), zero out safe_a so the tree-walk always falls
    # through to KNN. Calibration on bit-exact mojo-side normalization is
    # still pending, so ship disabled-by-default for FN=0/FP=0 safety.
    var fp_env = getenv("RINHA_FASTPATH")
    var fp_on = (fp_env.byte_length() > 0
                 and fp_env.unsafe_ptr()[0] == UInt8(ord("1")))
    if not fp_on:
        var zi: Int = 0
        while zi < 512:
            tree.safe_a[zi] = UInt8(0)
            zi += 1

    return Index(
        centroids,
        n_cb,
        bmin,
        bmax,
        offs,
        cnts,
        vecs,
        lbls,
        k,
        n,
        nb,
        tree,
    )


@always_inline
def scan_cluster(
    idx: Index,
    q: UnsafePointer[Int16, origin=MutExternalOrigin],
    cluster: UInt32,
    best_d: UnsafePointer[Int64, origin=MutExternalOrigin],
    best_l: UnsafePointer[UInt8, origin=MutExternalOrigin],
):
    var start_block = Int(idx.block_offsets[Int(cluster)])
    var end_block = Int(idx.block_offsets[Int(cluster) + 1])
    var total = Int(idx.counts[Int(cluster)])
    if total == 0:
        return

    var blk = start_block
    var processed: Int = 0
    while blk < end_block:
        var threshold = best_d[TOP_K - 1]
        var pr = blk_dist_prune(idx.vectors_base, blk, q, threshold)
        var dists = pr[0]
        var pruned = pr[1]
        var lane_n = LANES if (total - processed) >= LANES else (
            total - processed
        )
        processed += lane_n
        if pruned:
            blk += 1
            continue
        var lab_base = blk * LANES
        var lane: Int = 0
        while lane < lane_n:
            var d = dists[lane]
            if d < best_d[TOP_K - 1]:
                var label = idx.labels[lab_base + lane]
                insert_best(d, label, best_d, best_l)
            lane += 1
        blk += 1


@always_inline
def score(
    idx: Index, qf: UnsafePointer[Float32, origin=MutExternalOrigin]
) -> UInt32:
    # NOTE: heap-allocated scratch buffers via libc_malloc.
    # We previously used InlineArray[...] but Mojo b1 codegen elides writes
    # to InlineArray storage when the array is read indirectly through
    # `unsafe_ptr()` + extern/SIMD intrinsics (libKGENCompilerRTShared),
    # which crashed the worker on /fraud-score under load.
    var qbuf_raw = libc_malloc(PADDED_DIMS * 2)
    var q = qbuf_raw.bitcast[Int16]()
    quantize(qf, q)

    # Decision-tree fast-path (Modo A): walk the pre-trained tree and, if the
    # resulting leaf is marked safe, return its predicted count without
    # touching KNN. safe_a is gated by RINHA_FASTPATH at startup; when the
    # env is unset every entry of safe_a is zero so this never short-circuits.
    var t_node: Int32 = 0
    while True:
        var ni = Int(t_node)
        var lc = idx.tree_lefts[ni]
        if lc < 0:
            var leaf = Int(-1 - Int(lc))
            if idx.tree_safe_a[leaf] != UInt8(0):
                libc_free(qbuf_raw)
                return UInt32(idx.tree_leaf_count[leaf])
            break
        var f = Int(idx.tree_feats[ni])
        var thr = idx.tree_thrs[ni]
        if q[f] <= thr:
            t_node = lc
        else:
            t_node = idx.tree_rights[ni]

    var probes_c_raw = libc_malloc(MAX_PROBES * 4)
    var probes_d_raw = libc_malloc(MAX_PROBES * 8)
    var pc = probes_c_raw.bitcast[UInt32]()
    var pd = probes_d_raw.bitcast[Int64]()
    var probe_count: Int = 0

    var cb: Int = 0
    while cb < idx.n_centroid_blocks:
        var dists = blk_dist(idx.centroids_base, cb, q)
        var ci_base: Int = cb * LANES
        var lane_max = LANES
        if idx.k - ci_base < LANES:
            lane_max = idx.k - ci_base
        var lane: Int = 0
        while lane < lane_max:
            var ci = ci_base + lane
            if idx.counts[ci] != 0:
                insert_probe(pc, pd, probe_count, UInt32(ci), dists[lane])
            lane += 1
        cb += 1

    heap_to_sorted(pc, pd, probe_count)

    var best_d_raw = libc_malloc(TOP_K * 8)
    var best_l_raw = libc_malloc(TOP_K)
    var best_d = best_d_raw.bitcast[Int64]()
    var best_l = best_l_raw

    comptime for i in range(TOP_K):
        best_d[i] = I64_MAX
        best_l[i] = 0

    var n_initial = NPROBE if probe_count >= NPROBE else probe_count
    var pi: Int = 0
    while pi < n_initial:
        scan_cluster(idx, q, pc[pi], best_d, best_l)
        pi += 1

    var frauds: UInt8 = 0

    comptime for j in range(TOP_K):
        frauds += best_l[j]

    var unanimous = frauds == 0 or frauds == UInt8(TOP_K)
    var tight = best_d[TOP_K - 1] <= EARLY_DIST

    if unanimous and tight:
        libc_free(qbuf_raw)
        libc_free(probes_c_raw)
        libc_free(probes_d_raw)
        libc_free(best_d_raw)
        libc_free(best_l_raw)
        return UInt32(frauds)

    pi = NPROBE
    while pi < probe_count:
        var cluster = pc[pi]
        var lb = bbox_lower_bound(
            q,
            idx.bbox_min + Int(cluster) * PADDED_DIMS,
            idx.bbox_max + Int(cluster) * PADDED_DIMS,
        )
        if lb < best_d[TOP_K - 1]:
            scan_cluster(idx, q, cluster, best_d, best_l)
            frauds = 0

            comptime for j in range(TOP_K):
                frauds += best_l[j]
            if frauds < REPAIR_MIN or frauds > REPAIR_MAX_FRAUDS:
                if best_d[TOP_K - 1] <= EARLY_DIST:
                    break
        pi += 1

    frauds = 0

    comptime for j in range(TOP_K):
        frauds += best_l[j]

    var still_borderline = (
        frauds >= REPAIR_MIN and frauds <= REPAIR_MAX_FRAUDS
    )
    if still_borderline:
        var seen_raw = libc_malloc(SEEN_WORDS * 8)
        var seen = seen_raw.bitcast[UInt64]()
        var sj: Int = 0
        while sj < SEEN_WORDS:
            seen[sj] = 0
            sj += 1
        var pj: Int = 0
        while pj < probe_count:
            var c = Int(pc[pj])
            var w = c // 64
            var b = c % 64
            if w < SEEN_WORDS:
                seen[w] = seen[w] | (UInt64(1) << UInt64(b))
            pj += 1
        var ci: Int = 0
        while ci < idx.k:
            if idx.counts[ci] != 0:
                var w = ci // 64
                var b = ci % 64
                if (seen[w] >> UInt64(b)) & UInt64(1) == UInt64(0):
                    var lb = bbox_lower_bound(
                        q,
                        idx.bbox_min + ci * PADDED_DIMS,
                        idx.bbox_max + ci * PADDED_DIMS,
                    )
                    if lb < best_d[TOP_K - 1]:
                        scan_cluster(idx, q, UInt32(ci), best_d, best_l)
            ci += 1

        frauds = 0

        comptime for j in range(TOP_K):
            frauds += best_l[j]

        libc_free(seen_raw)

    libc_free(qbuf_raw)
    libc_free(probes_c_raw)
    libc_free(probes_d_raw)
    libc_free(best_d_raw)
    libc_free(best_l_raw)
    return UInt32(frauds)
