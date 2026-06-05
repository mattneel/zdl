// CRUD benchmark. Every row is a real library operation:
//   wire    — immutable wire-format ops (serialize/deserialize/serializeArray/query)
//   mutable — zdl.mutable.MutableContainer ops (per-record CRC sidecar,
//             tombstone deletes, compaction fences; wire format unchanged)
const std = @import("std");
const zdl = @import("zdl");

const TestStruct = struct {
    id: u64,
    data: [100]u8,

    pub const zdl_config = .{ .version = 1 };
};

const MC = zdl.mutable.MutableContainer(TestStruct);

const RECORD_SIZE: usize = @sizeOf(TestStruct); // 112
const N_BIG: usize = 65_536; // 7.0 MiB items region

// --- cheap deterministic RNG (xorshift64 + Lemire bound), ~2 ns ---
var rng_state: u64 = 0x9E3779B97F4A7C15;
inline fn nextRand() u64 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    rng_state = x;
    return x;
}
inline fn boundedRand(bound: usize) usize {
    return @truncate((@as(u128, nextRand()) * @as(u128, bound)) >> 64);
}

// --- result table ---
const Row = struct {
    label: []const u8,
    kind: []const u8, // "wire" | "mutable"
    ops_per_sec: f64,
    ns_per_op: f64,
};
var rows: [32]Row = undefined;
var nrows: usize = 0;

fn addRow(label: []const u8, kind: []const u8, ops: usize, elapsed_ns: u64) void {
    std.debug.assert(nrows < rows.len);
    const ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ops));
    rows[nrows] = .{
        .label = label,
        .kind = kind,
        .ops_per_sec = 1e9 / ns,
        .ns_per_op = ns,
    };
    nrows += 1;
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var sink: u64 = 0;

    // ---------- setup (untimed) ----------
    const source_items = try allocator.alloc(TestStruct, N_BIG);
    defer allocator.free(source_items);
    for (source_items, 0..) |*item, idx| {
        item.* = .{ .id = idx, .data = [_]u8{@truncate(idx)} ** 100 };
    }

    const container = @constCast(try zdl.format.serializeArray(TestStruct, source_items, .cpu, allocator));
    defer allocator.free(container);

    // shuffled victim order for reproducible tombstone densities (untimed prep)
    const victim_order = try allocator.alloc(u32, N_BIG);
    defer allocator.free(victim_order);
    {
        var prng = std.Random.DefaultPrng.init(42);
        const random = prng.random();
        for (victim_order, 0..) |*v, k| v.* = @intCast(k);
        random.shuffle(u32, victim_order);
    }

    // the mutable container under test (sidecar built here, untimed —
    // load-time cost, same class as query's one-time container CRC)
    var mc = try MC.fromItems(allocator, source_items, N_BIG);
    defer mc.deinit();

    // =========================================================
    // C — Create
    // =========================================================
    {
        var data = TestStruct{ .id = 1, .data = [_]u8{42} ** 100 };
        var buf: [zdl.serialize.serializedSize(TestStruct, .cpu)]u8 = undefined;
        const iterations: usize = 1_000_000;
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            data.id = i;
            const bytes = try zdl.serialize.serializeInto(&buf, data, .cpu);
            sink +%= bytes[zdl.format.HEADER_SIZE];
        }
        addRow("C  serializeInto, single blob", "wire", iterations, timer.read());
    }
    {
        const builds: usize = 20;
        var timer = try std.time.Timer.start();
        var b: usize = 0;
        while (b < builds) : (b += 1) {
            source_items[0].id = b; // vary input
            const bytes = try zdl.format.serializeArray(TestStruct, source_items, .cpu, allocator);
            sink +%= bytes[zdl.format.HEADER_SIZE + 8];
            allocator.free(@constCast(bytes));
        }
        addRow("C  bulk container build, per record", "wire", builds * N_BIG, timer.read());
        source_items[0].id = 0;
    }
    {
        // full-container working set (7 MiB), matching the wire Create arms
        var big = try MC.init(allocator, N_BIG);
        defer big.deinit();
        var rec = std.mem.zeroes(TestStruct);
        rec.data = [_]u8{7} ** 100;
        const rounds: usize = 16;
        var total_ns: u64 = 0;
        var r: usize = 0;
        var id: u64 = 0;
        while (r < rounds) : (r += 1) {
            var timer = try std.time.Timer.start();
            var k: usize = 0;
            while (k < N_BIG) : (k += 1) {
                rec.id = id;
                id += 1;
                _ = big.append(rec) catch unreachable;
            }
            total_ns += timer.read();
            sink +%= big.record_crcs[N_BIG - 1];
            // untimed reset: tombstone everything, compact back to empty
            var slot: usize = 0;
            while (slot < big.len) : (slot += 1) big.delete(slot) catch unreachable;
            big.compact();
        }
        addRow("C  MutableContainer append", "mutable", rounds * N_BIG, total_ns);
    }

    // =========================================================
    // R — Read
    // =========================================================
    {
        // verified single-blob read: rotation of 16 wires
        const num_wires = 16;
        var wires: [num_wires][]const u8 = undefined;
        for (&wires, 0..) |*wire, idx| {
            const payload = TestStruct{ .id = idx, .data = [_]u8{42} ** 100 };
            wire.* = try zdl.serialize.serialize(payload, .cpu, allocator);
        }
        defer for (wires) |wire| allocator.free(@constCast(wire));

        const iterations: usize = 1_000_000;
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const result = try zdl.deserialize.deserialize(TestStruct, wires[i % num_wires], allocator);
            sink +%= result.id;
        }
        addRow("R  deserialize blob + CRC verify", "wire", iterations, timer.read());
    }
    {
        // zero-copy point read
        const iterations: usize = 10_000_000;
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const idx = nextRand() & (N_BIG - 1);
            const rec = try mc.get(idx);
            sink +%= rec.id;
        }
        addRow("R  MutableContainer get (zero-copy)", "mutable", iterations, timer.read());
    }
    {
        // integrity-checked point read: O(record), not O(container)
        const iterations: usize = 2_000_000;
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const idx = nextRand() & (N_BIG - 1);
            const rec = try mc.getVerified(idx);
            std.mem.doNotOptimizeAway(&rec);
            sink +%= rec.id;
        }
        addRow("R  MutableContainer getVerified", "mutable", iterations, timer.read());
    }
    {
        // full scan through the query iterator (container CRC verified once, on warm-up)
        var qb = zdl.query.query(TestStruct, container, allocator);
        defer qb.deinit();
        {
            var warm = try qb.iter();
            _ = warm.next();
        }
        const scans: usize = 200;
        var timer = try std.time.Timer.start();
        var s: usize = 0;
        while (s < scans) : (s += 1) {
            var it = try qb.iter();
            while (it.next()) |item| sink +%= item.id;
        }
        addRow("R  full scan, query iter, per row", "wire", scans * N_BIG, timer.read());
    }

    // =========================================================
    // U — Update
    // =========================================================
    {
        // single-blob read-modify-write: the immutable wire path's update
        var buf: [zdl.serialize.serializedSize(TestStruct, .cpu)]u8 = undefined;
        _ = try zdl.serialize.serializeInto(&buf, TestStruct{ .id = 0, .data = [_]u8{42} ** 100 }, .cpu);
        const iterations: usize = 1_000_000;
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var record = try zdl.deserialize.deserialize(TestStruct, &buf, allocator);
            record.id = i;
            _ = try zdl.serialize.serializeInto(&buf, record, .cpu);
            sink +%= record.id;
        }
        addRow("U  blob RMW (deser+mut+ser)", "wire", iterations, timer.read());
    }
    {
        // in-place record update: canonicalize + write + re-CRC one record
        var rec = std.mem.zeroes(TestStruct);
        rec.data = [_]u8{42} ** 100;
        const iterations: usize = 2_000_000;
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const idx = nextRand() & (N_BIG - 1);
            rec.id = i;
            try mc.update(idx, rec);
            sink +%= mc.record_crcs[idx];
        }
        addRow("U  MutableContainer update", "mutable", iterations, timer.read());
    }

    // =========================================================
    // D — Delete
    // =========================================================
    {
        // tombstone delete: random live victim (retry on tombstoned is part
        // of the real cost of random-victim deletion)
        const per_drain: usize = N_BIG / 2;
        const drains: usize = 20;
        var total_ns: u64 = 0;
        var d: usize = 0;
        var refill = std.mem.zeroes(TestStruct);
        while (d < drains) : (d += 1) {
            var timer = try std.time.Timer.start();
            var deleted: usize = 0;
            while (deleted < per_drain) {
                const idx = boundedRand(mc.len);
                mc.delete(idx) catch continue;
                deleted += 1;
            }
            total_ns += timer.read();
            sink +%= mc.live;
            // untimed restore: compact, refill to N_BIG
            mc.compact();
            while (mc.len < N_BIG) {
                refill.id = mc.len;
                _ = mc.append(refill) catch unreachable;
            }
        }
        addRow("D  MutableContainer tombstone", "mutable", drains * per_drain, total_ns);
    }
    {
        // deletes plus their share of the compaction that reclaims them
        // (sidecar CRCs move, nothing is recomputed)
        const per_rep: usize = N_BIG / 2;
        const reps: usize = 10;
        var total_ns: u64 = 0;
        var r: usize = 0;
        var refill = std.mem.zeroes(TestStruct);
        while (r < reps) : (r += 1) {
            var timer = try std.time.Timer.start();
            var deleted: usize = 0;
            while (deleted < per_rep) {
                const idx = boundedRand(mc.len);
                mc.delete(idx) catch continue;
                deleted += 1;
            }
            mc.compact();
            total_ns += timer.read();
            sink +%= mc.generation;
            while (mc.len < N_BIG) { // untimed refill
                refill.id = mc.len;
                _ = mc.append(refill) catch unreachable;
            }
        }
        addRow("D  tombstone + compaction share", "mutable", reps * per_rep, total_ns);
    }
    {
        // read-path tax: full scan through the iterator at tombstone densities
        const scans: usize = 200;
        const densities = [_]struct { label: []const u8, count: usize }{
            .{ .label = "D  iter scan, 0% dead, per slot", .count = 0 },
            .{ .label = "D  iter scan, 10% dead, per slot", .count = N_BIG / 10 },
            .{ .label = "D  iter scan, 50% dead, per slot", .count = N_BIG / 2 },
        };
        var refill = std.mem.zeroes(TestStruct);
        for (densities) |density| {
            for (victim_order[0..density.count]) |v| mc.delete(v) catch unreachable;
            var timer = try std.time.Timer.start();
            var s: usize = 0;
            while (s < scans) : (s += 1) {
                var it = mc.iter();
                while (try it.next()) |rec| sink +%= rec.id;
            }
            addRow(density.label, "mutable", scans * N_BIG, timer.read());
            mc.compact(); // untimed restore
            while (mc.len < N_BIG) {
                refill.id = mc.len;
                _ = mc.append(refill) catch unreachable;
            }
        }
    }

    std.mem.doNotOptimizeAway(&sink);

    // ---------- report ----------
    std.debug.print("CRUD Benchmark\n", .{});
    std.debug.print("  record: {d} B payload; container: {d} records / {d:.1} MiB\n\n", .{
        RECORD_SIZE, N_BIG, @as(f64, @floatFromInt(N_BIG * RECORD_SIZE)) / (1024.0 * 1024.0),
    });
    std.debug.print("  {s:<40} {s:>9} {s:>14} {s:>10}\n", .{ "op", "kind", "ops/sec", "ns/op" });
    for (rows[0..nrows]) |row| {
        std.debug.print("  {s:<40} {s:>9} {d:>14.0} {d:>10.1}\n", .{
            row.label, row.kind, row.ops_per_sec, row.ns_per_op,
        });
    }
}
