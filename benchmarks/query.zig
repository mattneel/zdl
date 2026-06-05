const std = @import("std");
const zdl = @import("zdl");

const Sample = struct {
    id: u64,
    score: f32,

    pub const zdl_config = .{ .version = 1 };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const count: usize = 256 * 1024;
    const items = try allocator.alloc(Sample, count);
    defer allocator.free(items);

    for (items, 0..) |*sample, idx| {
        sample.* = .{
            .id = @intCast(idx),
            .score = @floatFromInt(idx % 1000),
        };
    }

    const bytes = try zdl.format.serializeArray(Sample, items, .cpu, allocator);
    defer allocator.free(@constCast(bytes));

    // Load: the first iter() validates the header and CRCs the whole
    // container (one-time cost, previously hidden inside the scan number).
    // Min of 3 fresh builders: a single ~5ms sample has unmeasured variance.
    var load_ns: u64 = std.math.maxInt(u64);
    {
        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            var fresh = zdl.query.query(Sample, bytes, allocator);
            defer fresh.deinit();
            var load_timer = try std.time.Timer.start();
            _ = try fresh.iter();
            load_ns = @min(load_ns, load_timer.read());
        }
    }

    var qb = zdl.query.query(Sample, bytes, allocator);
    defer qb.deinit();
    _ = try qb.iter(); // warm: validate once, untimed

    // Scan: pure iteration; container CRC already verified above.
    const scans: usize = 100;
    var sink: u64 = 0;
    var processed: usize = 0;
    var timer = try std.time.Timer.start();
    var s: usize = 0;
    while (s < scans) : (s += 1) {
        var iter = try qb.iter();
        while (iter.next()) |item| {
            sink +%= item.id;
            processed += 1;
        }
    }
    const elapsed_ns = timer.read();
    std.mem.doNotOptimizeAway(&sink);

    const container_bytes = @as(f64, @floatFromInt(count * @sizeOf(Sample)));
    const load_s = @as(f64, @floatFromInt(load_ns)) / 1_000_000_000.0;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const rows_per_sec = @as(f64, @floatFromInt(processed)) / elapsed_s;
    const scan_mb_per_sec = (rows_per_sec * @as(f64, @floatFromInt(@sizeOf(Sample)))) / (1024.0 * 1024.0);
    const load_mb_per_sec = container_bytes / load_s / (1024.0 * 1024.0);

    std.debug.print("Query Benchmark\n", .{});
    std.debug.print("  load+verify (one-time container CRC):\n", .{});
    std.debug.print("    {d:.2} ms ({d:.2} MB/sec)\n", .{ load_s * 1000.0, load_mb_per_sec });
    std.debug.print("  scan:\n", .{});
    std.debug.print("    {d:.0} rows/sec\n", .{rows_per_sec});
    std.debug.print("    {d:.2} MB/sec\n", .{scan_mb_per_sec});
}
