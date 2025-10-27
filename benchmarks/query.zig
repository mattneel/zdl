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

    var qb = zdl.query.query(Sample, bytes, allocator);
    defer qb.deinit();

    var timer = try std.time.Timer.start();
    var iter = try qb.iter();
    var processed: usize = 0;
    while (iter.next()) |_| {
        processed += 1;
    }
    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(processed)) / elapsed_s;
    const bytes_per_op = @as(f64, @floatFromInt(@sizeOf(Sample)));
    const mb_per_sec = (ops_per_sec * bytes_per_op) / (1024.0 * 1024.0);

    std.debug.print("Query Benchmark\n", .{});
    std.debug.print("  {d:.0} rows/sec\n", .{ops_per_sec});
    std.debug.print("  {d:.2} MB/sec\n", .{mb_per_sec});
}
