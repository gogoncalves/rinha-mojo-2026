const std = @import("std");

const DIMS: usize = 14;
const PADDED_DIMS: usize = 16;
const LANES: usize = 8;
const QUANT_SCALE: f32 = 10000.0;
const QUANT_MAX: f32 = 10000.0;
const MAGIC: u32 = 0x52494E48;
const VERSION: u32 = 4;
const K: usize = 4096;
const KMEANS_ITERS: usize = 15;
const KMEANS_SAMPLE: usize = 500_000;
const SEED: u64 = 0xDEADBEEFCAFEBABE;

const Header = extern struct {
    magic: u32,
    version: u32,
    k: u32,
    n: u32,
    n_blocks: u32,
    scale: f32,
    _r: [40]u8,
};

const Rng = struct {
    s: u64,
    fn init(seed: u64) Rng { return .{ .s = if (seed == 0) 1 else seed }; }
    fn next(self: *Rng) u64 {
        var x = self.s;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.s = x;
        return x;
    }
    fn pick(self: *Rng, n: usize) usize { return @intCast(self.next() % n); }
    fn unit(self: *Rng) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) / @as(f64, @floatFromInt(1 << 53));
    }
};

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn close(fd: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn fstat(fd: c_int, buf: *anyopaque) c_int;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

const O_RDONLY = 0;
const O_WRONLY = 1;
const O_CREAT = 0o100;
const O_TRUNC = 0o1000;

const StatBuf = extern struct {
    pad0: [48]u8,
    size: i64,
    pad1: [80]u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const in_path = std.c.getenv("INPUT") orelse {
        std.debug.print("set INPUT=path/to/references.json (decompressed)\n", .{});
        return;
    };
    const out_path = std.c.getenv("OUTPUT") orelse {
        std.debug.print("set OUTPUT=path/to/index.bin\n", .{});
        return;
    };

    var t0 = std.time.milliTimestamp();
    std.debug.print("reading {s}\n", .{std.mem.span(in_path)});
    const fd = open(in_path, O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var st: StatBuf = undefined;
    if (fstat(fd, &st) < 0) return error.StatFailed;
    const size: usize = @intCast(st.size);
    std.debug.print("size: {d} MB\n", .{size / 1024 / 1024});
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    var got: usize = 0;
    while (got < size) {
        const r = read(fd, bytes.ptr + got, size - got);
        if (r <= 0) return error.ReadFailed;
        got += @intCast(r);
    }
    std.debug.print("read in {d}ms\n", .{std.time.milliTimestamp() - t0});

    t0 = std.time.milliTimestamp();
    var vecs = std.ArrayList([DIMS]f32).init(allocator);
    defer vecs.deinit();
    var labels = std.ArrayList(u8).init(allocator);
    defer labels.deinit();
    try parseAll(bytes, &vecs, &labels);
    std.debug.print("parsed {d} vecs in {d}ms\n", .{ vecs.items.len, std.time.milliTimestamp() - t0 });

    t0 = std.time.milliTimestamp();
    const centers = try allocator.alloc([DIMS]f32, K);
    defer allocator.free(centers);
    try kmeansPlusPlus(allocator, vecs.items, centers, KMEANS_ITERS);
    std.debug.print("k-means++ in {d}ms\n", .{std.time.milliTimestamp() - t0});

    t0 = std.time.milliTimestamp();
    const n = vecs.items.len;
    const assignments = try allocator.alloc(u32, n);
    defer allocator.free(assignments);
    const counts = try allocator.alloc(u32, K);
    defer allocator.free(counts);
    @memset(counts, 0);
    for (vecs.items, 0..) |v, i| {
        const c = nearest(centers, v);
        assignments[i] = c;
        counts[c] += 1;
    }
    var max_c: u32 = 0;
    var min_c: u32 = std.math.maxInt(u32);
    for (counts) |c| {
        if (c > max_c) max_c = c;
        if (c < min_c) min_c = c;
    }
    std.debug.print("assign in {d}ms - bucket min={d} max={d} avg={d}\n", .{
        std.time.milliTimestamp() - t0, min_c, max_c, n / K,
    });

    const blocks_per_cluster = try allocator.alloc(u32, K);
    defer allocator.free(blocks_per_cluster);
    var total_blocks: u32 = 0;
    for (counts, 0..) |c, i| {
        const b: u32 = (c + @as(u32, LANES) - 1) / @as(u32, LANES);
        blocks_per_cluster[i] = b;
        total_blocks += b;
    }
    const block_offsets = try allocator.alloc(u32, K + 1);
    defer allocator.free(block_offsets);
    block_offsets[0] = 0;
    for (0..K) |i| block_offsets[i + 1] = block_offsets[i] + blocks_per_cluster[i];

    const bbox_min = try allocator.alloc([PADDED_DIMS]i16, K);
    defer allocator.free(bbox_min);
    const bbox_max = try allocator.alloc([PADDED_DIMS]i16, K);
    defer allocator.free(bbox_max);
    for (0..K) |i| {
        bbox_min[i] = .{std.math.maxInt(i16)} ** PADDED_DIMS;
        bbox_max[i] = .{std.math.minInt(i16)} ** PADDED_DIMS;
    }

    const codes_words: usize = @as(usize, total_blocks) * PADDED_DIMS * LANES;
    const codes = try allocator.alloc(i16, codes_words);
    defer allocator.free(codes);
    @memset(codes, 0);
    const lbls = try allocator.alloc(u8, @as(usize, total_blocks) * LANES);
    defer allocator.free(lbls);
    @memset(lbls, 0);

    const cluster_idx = try allocator.alloc([]u32, K);
    defer {
        for (cluster_idx) |arr| allocator.free(arr);
        allocator.free(cluster_idx);
    }
    for (counts, 0..) |c, i| {
        cluster_idx[i] = try allocator.alloc(u32, c);
    }
    {
        const cur = try allocator.alloc(u32, K);
        defer allocator.free(cur);
        @memset(cur, 0);
        for (assignments, 0..) |c, i| {
            cluster_idx[c][cur[c]] = @intCast(i);
            cur[c] += 1;
        }
    }
    for (cluster_idx, 0..) |arr, ci| {
        const ctx = SortCtx{ .vecs = vecs.items, .center = centers[ci] };
        std.mem.sort(u32, arr, ctx, sortByDist);
    }

    const cur_block = try allocator.alloc(u32, K);
    defer allocator.free(cur_block);
    const cur_lane = try allocator.alloc(u8, K);
    defer allocator.free(cur_lane);
    for (0..K) |i| {
        cur_block[i] = block_offsets[i];
        cur_lane[i] = 0;
    }

    for (cluster_idx, 0..) |arr, c| {
        for (arr) |i| {
            const v = vecs.items[i];
            var q: [PADDED_DIMS]i16 = .{0} ** PADDED_DIMS;
            inline for (0..DIMS) |j| {
                var x = v[j] * QUANT_SCALE;
                if (x > QUANT_MAX) x = QUANT_MAX else if (x < -QUANT_MAX) x = -QUANT_MAX;
                q[j] = @intFromFloat(@round(x));
            }
            inline for (0..PADDED_DIMS) |j| {
                if (q[j] < bbox_min[c][j]) bbox_min[c][j] = q[j];
                if (q[j] > bbox_max[c][j]) bbox_max[c][j] = q[j];
            }
            const block_idx: usize = cur_block[c];
            const lane: usize = cur_lane[c];
            const block_base = block_idx * PADDED_DIMS * LANES;
            inline for (0..PADDED_DIMS / 2) |p| {
                const pair_base = block_base + p * LANES * 2;
                codes[pair_base + lane * 2] = q[p * 2];
                codes[pair_base + lane * 2 + 1] = q[p * 2 + 1];
            }
            lbls[block_idx * LANES + lane] = labels.items[i];
            cur_lane[c] += 1;
            if (cur_lane[c] == LANES) {
                cur_lane[c] = 0;
                cur_block[c] += 1;
            }
        }
    }

    const centroids_q = try allocator.alloc([PADDED_DIMS]i16, K);
    defer allocator.free(centroids_q);
    for (centers, 0..) |c, i| {
        var q: [PADDED_DIMS]i16 = .{0} ** PADDED_DIMS;
        inline for (0..DIMS) |j| {
            var x = c[j] * QUANT_SCALE;
            if (x > QUANT_MAX) x = QUANT_MAX else if (x < -QUANT_MAX) x = -QUANT_MAX;
            q[j] = @intFromFloat(@round(x));
        }
        centroids_q[i] = q;
    }

    const n_centroid_blocks: usize = (K + LANES - 1) / LANES;
    const centroid_soa = try allocator.alloc(i16, n_centroid_blocks * PADDED_DIMS * LANES);
    defer allocator.free(centroid_soa);
    @memset(centroid_soa, 0);
    for (centroids_q, 0..) |c, ci| {
        const block_idx = ci / LANES;
        const lane = ci % LANES;
        const block_base = block_idx * PADDED_DIMS * LANES;
        inline for (0..PADDED_DIMS / 2) |p| {
            const pair_base = block_base + p * LANES * 2;
            centroid_soa[pair_base + lane * 2] = c[p * 2];
            centroid_soa[pair_base + lane * 2 + 1] = c[p * 2 + 1];
        }
    }

    t0 = std.time.milliTimestamp();
    const ofd = open(out_path, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (ofd < 0) return error.CreateFailed;
    defer _ = close(ofd);

    const hdr = Header{
        .magic = MAGIC,
        .version = VERSION,
        .k = K,
        .n = @intCast(n),
        .n_blocks = total_blocks,
        .scale = QUANT_SCALE,
        ._r = .{0} ** 40,
    };
    try writeAll(ofd, std.mem.asBytes(&hdr));
    try writeAll(ofd, std.mem.sliceAsBytes(centroid_soa));
    for (bbox_min) |b| try writeAll(ofd, std.mem.sliceAsBytes(b[0..]));
    for (bbox_max) |b| try writeAll(ofd, std.mem.sliceAsBytes(b[0..]));
    try writeAll(ofd, std.mem.sliceAsBytes(block_offsets[0..]));
    try writeAll(ofd, std.mem.sliceAsBytes(counts[0..]));
    try writeAll(ofd, std.mem.sliceAsBytes(codes));
    try writeAll(ofd, lbls);
    std.debug.print("write in {d}ms - n={d} k={d} blocks={d}\n", .{
        std.time.milliTimestamp() - t0, n, K, total_blocks,
    });
}

const SortCtx = struct {
    vecs: []const [DIMS]f32,
    center: [DIMS]f32,
};

fn sortByDist(ctx: SortCtx, a: u32, b: u32) bool {
    var da: f32 = 0;
    var db: f32 = 0;
    inline for (0..DIMS) |j| {
        const ea = ctx.vecs[a][j] - ctx.center[j];
        const eb = ctx.vecs[b][j] - ctx.center[j];
        da += ea * ea;
        db += eb * eb;
    }
    return da < db;
}

fn writeAll(fd: c_int, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const w = write(fd, data.ptr + sent, data.len - sent);
        if (w <= 0) return error.WriteFailed;
        sent += @intCast(w);
    }
}

fn parseAll(buf: []const u8, vecs: *std.ArrayList([DIMS]f32), labels: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    while (i < buf.len and buf[i] != '[') : (i += 1) {}
    if (i == buf.len) return;
    i += 1;
    while (i < buf.len) {
        while (i < buf.len and isSpace(buf[i])) : (i += 1) {}
        if (i >= buf.len or buf[i] == ']') return;
        if (buf[i] != '{') { i += 1; continue; }
        i += 1;
        var v: [DIMS]f32 = undefined;
        var lab: u8 = 0;
        var got_v = false;
        var got_l = false;
        while (i < buf.len and buf[i] != '}') {
            while (i < buf.len and (isSpace(buf[i]) or buf[i] == ',')) : (i += 1) {}
            if (i >= buf.len or buf[i] == '}') break;
            if (buf[i] != '"') { i += 1; continue; }
            i += 1;
            const ks = i;
            while (i < buf.len and buf[i] != '"') : (i += 1) {}
            const key = buf[ks..i];
            if (i < buf.len) i += 1;
            while (i < buf.len and (isSpace(buf[i]) or buf[i] == ':')) : (i += 1) {}
            if (std.mem.eql(u8, key, "vector")) {
                try parseVector(buf, &i, &v);
                got_v = true;
            } else if (std.mem.eql(u8, key, "label")) {
                lab = try parseLabel(buf, &i);
                got_l = true;
            } else {
                skipVal(buf, &i);
            }
        }
        if (i < buf.len) i += 1;
        if (got_v and got_l) {
            try vecs.append(v);
            try labels.append(lab);
        }
        while (i < buf.len and (isSpace(buf[i]) or buf[i] == ',')) : (i += 1) {}
    }
}

fn parseVector(buf: []const u8, i: *usize, out: *[DIMS]f32) !void {
    while (i.* < buf.len and buf[i.*] != '[') : (i.* += 1) {}
    if (i.* >= buf.len) return error.Bad;
    i.* += 1;
    var k: usize = 0;
    while (i.* < buf.len and k < DIMS) {
        while (i.* < buf.len and (isSpace(buf[i.*]) or buf[i.*] == ',')) : (i.* += 1) {}
        if (buf[i.*] == ']') break;
        const start = i.*;
        while (i.* < buf.len) : (i.* += 1) {
            const c = buf[i.*];
            if (c == ',' or c == ']' or isSpace(c)) break;
        }
        out[k] = try std.fmt.parseFloat(f32, buf[start..i.*]);
        k += 1;
    }
    while (i.* < buf.len and buf[i.*] != ']') : (i.* += 1) {}
    if (i.* < buf.len) i.* += 1;
}

fn parseLabel(buf: []const u8, i: *usize) !u8 {
    while (i.* < buf.len and buf[i.*] != '"') : (i.* += 1) {}
    i.* += 1;
    const start = i.*;
    while (i.* < buf.len and buf[i.*] != '"') : (i.* += 1) {}
    const s = buf[start..i.*];
    i.* += 1;
    return if (std.mem.eql(u8, s, "fraud")) 1 else 0;
}

fn skipVal(buf: []const u8, i: *usize) void {
    while (i.* < buf.len and isSpace(buf[i.*])) : (i.* += 1) {}
    if (i.* >= buf.len) return;
    const c = buf[i.*];
    if (c == '"') {
        i.* += 1;
        while (i.* < buf.len and buf[i.*] != '"') : (i.* += 1) {}
        if (i.* < buf.len) i.* += 1;
        return;
    }
    if (c == '{' or c == '[') {
        const closer: u8 = if (c == '{') '}' else ']';
        var depth: u32 = 1;
        i.* += 1;
        while (i.* < buf.len and depth > 0) {
            if (buf[i.*] == c) depth += 1
            else if (buf[i.*] == closer) depth -= 1;
            i.* += 1;
        }
        return;
    }
    while (i.* < buf.len) : (i.* += 1) {
        const cc = buf[i.*];
        if (cc == ',' or cc == '}' or cc == ']') return;
    }
}

inline fn isSpace(c: u8) bool { return c == ' ' or c == '\t' or c == '\r' or c == '\n'; }

inline fn dist2_f32(a: [DIMS]f32, b: [DIMS]f32) f32 {
    var s: f32 = 0;
    inline for (0..DIMS) |j| { const d = a[j] - b[j]; s += d * d; }
    return s;
}

fn nearest(centers: []const [DIMS]f32, p: [DIMS]f32) u32 {
    var best: u32 = 0;
    var best_d: f32 = std.math.inf(f32);
    for (centers, 0..) |c, i| {
        const d = dist2_f32(p, c);
        if (d < best_d) { best_d = d; best = @intCast(i); }
    }
    return best;
}

fn kmeansPlusPlus(
    allocator: std.mem.Allocator,
    points: []const [DIMS]f32,
    centers: [][DIMS]f32,
    iters: usize,
) !void {
    var rng = Rng.init(SEED);
    const sample_n = @min(KMEANS_SAMPLE, points.len);

    const sample = try allocator.alloc([DIMS]f32, sample_n);
    defer allocator.free(sample);
    for (0..sample_n) |i| sample[i] = points[rng.pick(points.len)];

    centers[0] = sample[rng.pick(sample_n)];
    const min_dist = try allocator.alloc(f32, sample_n);
    defer allocator.free(min_dist);
    for (0..sample_n) |i| min_dist[i] = dist2_f32(sample[i], centers[0]);

    for (1..centers.len) |ci| {
        var sum: f64 = 0;
        for (min_dist) |d| sum += d;
        if (sum <= 0) {
            centers[ci] = sample[rng.pick(sample_n)];
        } else {
            const target = rng.unit() * sum;
            var acc: f64 = 0;
            var chosen: usize = sample_n - 1;
            for (min_dist, 0..) |d, i| {
                acc += d;
                if (acc >= target) { chosen = i; break; }
            }
            centers[ci] = sample[chosen];
        }
        for (0..sample_n) |i| {
            const d = dist2_f32(sample[i], centers[ci]);
            if (d < min_dist[i]) min_dist[i] = d;
        }
        if (ci % 256 == 0) std.debug.print("  k++ {d}/{d}\n", .{ ci, centers.len });
    }

    const sums = try allocator.alloc([DIMS]f64, centers.len);
    defer allocator.free(sums);
    const counts = try allocator.alloc(u64, centers.len);
    defer allocator.free(counts);

    for (0..iters) |it| {
        for (sums) |*s| s.* = .{0} ** DIMS;
        @memset(counts, 0);
        var sse: f64 = 0;
        for (sample) |p| {
            var best: usize = 0;
            var best_d: f32 = std.math.inf(f32);
            for (centers, 0..) |c, ci| {
                const d = dist2_f32(p, c);
                if (d < best_d) { best_d = d; best = ci; }
            }
            counts[best] += 1;
            inline for (0..DIMS) |j| sums[best][j] += p[j];
            sse += best_d;
        }
        for (centers, 0..) |*c, i| {
            if (counts[i] > 0) {
                const inv = 1.0 / @as(f64, @floatFromInt(counts[i]));
                inline for (0..DIMS) |j| c.*[j] = @floatCast(sums[i][j] * inv);
            } else {
                c.* = sample[rng.pick(sample.len)];
            }
        }
        std.debug.print("  iter {d} sse={d:.5}\n", .{ it, sse / @as(f64, @floatFromInt(sample.len)) });
    }
}
