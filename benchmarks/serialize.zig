const std = @import("std");
const zdl = @import("zdl");

const TestStruct = struct {
    id: u64,
    data: [100]u8,

    pub const zdl_config = .{ .version = 1 };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const iterations: usize = 10_000;
    const data = TestStruct{
        .id = 1,
        .data = [_]u8{42} ** 100,
    };

    var timer = try std.time.Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const bytes = try zdl.serialize.serialize(data, .cpu, allocator);
        allocator.free(@constCast(bytes));
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / elapsed_s;
    const bytes_per_op = @as(f64, @floatFromInt(@sizeOf(TestStruct) + zdl.format.HEADER_SIZE));
    const mb_per_sec = (ops_per_sec * bytes_per_op) / (1024.0 * 1024.0);

    std.debug.print("Serialization Benchmark\n", .{});
    std.debug.print("  {d:.0} ops/sec\n", .{ops_per_sec});
    std.debug.print("  {d:.2} MB/sec\n", .{mb_per_sec});
}
