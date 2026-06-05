const std = @import("std");
const zdl = @import("zdl");

const TestStruct = struct {
    id: u64,
    data: [100]u8,

    pub const zdl_config = .{ .version = 1 };
};

pub fn main() !void {
    const iterations: usize = 1_000_000;
    var data = TestStruct{
        .id = 1,
        .data = [_]u8{42} ** 100,
    };
    var sink: u64 = 0;

    // Hot path: zero-allocation serialize into a caller-provided buffer.
    var buf: [zdl.serialize.serializedSize(TestStruct, .cpu)]u8 = undefined;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        data.id = i; // vary input so the loop body cannot be hoisted
        const bytes = try zdl.serialize.serializeInto(&buf, data, .cpu);
        sink +%= bytes[zdl.format.HEADER_SIZE];
    }
    const into_ns = timer.read();

    // Allocating path: one alloc+free per record. Uses smp_allocator: the
    // former GeneralPurposeAllocator is a debug allocator (page-mapped per
    // bucket) and benchmarks the OS, not zdl.
    const allocator = std.heap.smp_allocator;
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        data.id = i;
        const bytes = try zdl.serialize.serialize(data, .cpu, allocator);
        sink +%= bytes[zdl.format.HEADER_SIZE];
        allocator.free(@constCast(bytes));
    }
    const alloc_ns = timer.read();

    std.mem.doNotOptimizeAway(&sink);

    std.debug.print("Serialization Benchmark\n", .{});
    printResult("serializeInto (zero-alloc)", iterations, into_ns);
    printResult("serialize (alloc per op)", iterations, alloc_ns);
}

fn printResult(name: []const u8, iterations: usize, elapsed_ns: u64) void {
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / elapsed_s;
    // Actual bytes written per record, including the alignment tail.
    const bytes_per_op = @as(f64, @floatFromInt(zdl.serialize.serializedSize(TestStruct, .cpu)));
    const mb_per_sec = (ops_per_sec * bytes_per_op) / (1024.0 * 1024.0);
    std.debug.print("  {s}:\n    {d:.0} ops/sec\n    {d:.2} MB/sec\n", .{ name, ops_per_sec, mb_per_sec });
}
