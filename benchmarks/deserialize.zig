const std = @import("std");
const zdl = @import("zdl");

const TestStruct = struct {
    id: u64,
    data: [100]u8,

    pub const zdl_config = .{ .version = 1 };
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    // Pre-serialize a rotation of distinct records so the deserialized value
    // is not loop-invariant (a constant input would let the optimizer hoist
    // or elide the work being measured).
    const num_wires = 16;
    var wires: [num_wires][]const u8 = undefined;
    for (&wires, 0..) |*wire, idx| {
        const payload = TestStruct{
            .id = idx,
            .data = [_]u8{42} ** 100,
        };
        wire.* = try zdl.serialize.serialize(payload, .cpu, allocator);
    }
    defer for (wires) |wire| allocator.free(@constCast(wire));

    const iterations: usize = 1_000_000;
    var sink: u64 = 0;
    var timer = try std.time.Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const result = try zdl.deserialize.deserialize(TestStruct, wires[i % num_wires], allocator);
        sink +%= result.id;
    }

    const elapsed_ns = timer.read();
    std.mem.doNotOptimizeAway(&sink);

    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / elapsed_s;
    // Actual wire bytes consumed per record, including the alignment tail.
    // Note: the 16-wire working set is L1-resident by design; MB/sec is
    // hot-cache record throughput, not memory bandwidth.
    const bytes_per_op = @as(f64, @floatFromInt(zdl.serialize.serializedSize(TestStruct, .cpu)));
    const mb_per_sec = (ops_per_sec * bytes_per_op) / (1024.0 * 1024.0);

    std.debug.print("Deserialization Benchmark\n", .{});
    std.debug.print("  {d:.0} ops/sec\n", .{ops_per_sec});
    std.debug.print("  {d:.2} MB/sec\n", .{mb_per_sec});
}
