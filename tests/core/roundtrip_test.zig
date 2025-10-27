const std = @import("std");
const zdl = @import("zdl");
const builtin = @import("builtin");

const Target = zdl.Target;
const serializer = zdl.serialize;
const deserializer = zdl.deserialize;
const format = zdl.format;
const schema = zdl.schema;

fn assertRoundTrip(comptime T: type, value: T, allocator: std.mem.Allocator) !void {
    const bytes = try serializer.serialize(value, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    const header_len = @as(usize, format.HEADER_SIZE);
    const header = try format.validateHeader(bytes[0..header_len]);
    const payload_len = @sizeOf(T);
    const aligned_len = std.mem.alignForward(usize, payload_len, Target.cpu.alignment());
    const payload = bytes[header_len .. header_len + aligned_len];
    const data_bytes = payload[0..payload_len];

    try std.testing.expectEqual(@as(u32, schemaVersion(T)), header.version);
    try std.testing.expectEqual(@as(u64, payload_len), header.length);
    try std.testing.expectEqual(std.hash.crc.Crc32.hash(data_bytes), header.checksum);

    if (aligned_len > payload_len) {
        const padding = payload[payload_len..];
        for (padding) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }

    const restored = try deserializer.deserialize(T, bytes, allocator);
    try std.testing.expectEqualDeep(value, restored);
}

fn schemaVersion(comptime T: type) u32 {
    if (@hasDecl(T, "zdl_config")) {
        const cfg = @field(T, "zdl_config");
        if (@hasField(@TypeOf(cfg), "version")) {
            return @intCast(cfg.version);
        }
    }
    return 0;
}

fn initLargeArray() [schema.max_array_len]u16 {
    var data = std.mem.zeroes([schema.max_array_len]u16);
    for (&data, 0..) |*slot, idx| {
        slot.* = @as(u16, @intCast(idx & 0xFFFF));
    }
    return data;
}

test "round trip simple struct" {
    const gpa = std.testing.allocator;
    const Sample = struct {
        id: u64,
        score: f32,
        active: bool,
        pub const zdl_config = .{ .version = 11 };
    };

    try assertRoundTrip(Sample, .{ .id = 42, .score = 3.14, .active = true }, gpa);
}

test "round trip complex nested struct" {
    const gpa = std.testing.allocator;

    const Level8 = struct { leaf: u16 };
    const Level7 = struct { node: Level8 };
    const Level6 = struct { node: Level7 };
    const Level5 = struct { node: Level6 };
    const Level4 = struct { node: Level5 };
    const Level3 = struct { node: Level4 };
    const Level2 = struct { node: Level3 };
    const Level1 = struct {
        node: Level2,
        pub const zdl_config = .{ .version = 5 };
    };
    const Complex = struct {
        header: u32,
        payload: Level1,
        checksum: u32,
    };

    const value = Complex{
        .header = 0xABCD1234,
        .payload = .{ .node = .{ .node = .{ .node = .{ .node = .{ .node = .{ .node = .{ .node = .{ .leaf = 99 } } } } } } } },
        .checksum = 0xFEEDFACE,
    };

    try assertRoundTrip(Complex, value, gpa);
}

test "round trip large array near schema limit" {
    const gpa = std.testing.allocator;
    const Large = struct {
        data: [schema.max_array_len]u16,
        count: u32,
        pub const zdl_config = .{ .version = 9 };
    };

    const value = Large{
        .data = initLargeArray(),
        .count = @intCast(schema.max_array_len),
    };

    try assertRoundTrip(Large, value, gpa);
}

test "round trip zero and max values" {
    const gpa = std.testing.allocator;
    const Extremes = struct {
        zero: u64,
        max_u32: u32,
        neg: i32,
        flag: bool,
        pub const zdl_config = .{ .version = 3 };
    };

    try assertRoundTrip(Extremes, .{
        .zero = 0,
        .max_u32 = std.math.maxInt(u32),
        .neg = std.math.minInt(i32),
        .flag = false,
    }, gpa);
}

test "serialize/deserialize throughput exceeds target" {
    const gpa = std.testing.allocator;
    const Benchmark = struct {
        payload: [4096]u64,
        pub const zdl_config = .{ .version = 1 };
    };

    var sample = Benchmark{ .payload = std.mem.zeroes([4096]u64) };
    for (&sample.payload, 0..) |*slot, idx| {
        slot.* = @as(u64, idx);
    }

    const iterations: usize = 256;
    var total_bytes: usize = 0;
    var timer = try std.time.Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const bytes = try serializer.serialize(sample, Target.cpu, gpa);
        total_bytes += bytes.len;
        const restored = try deserializer.deserialize(Benchmark, bytes, gpa);
        try std.testing.expectEqualDeep(sample, restored);
        gpa.free(@constCast(bytes));
    }

    const elapsed_ns = timer.read();
    if (elapsed_ns == 0) return;

    const bytes_f = @as(f128, @floatFromInt(total_bytes));
    const seconds = @as(f128, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const megabytes = bytes_f / 1_000_000.0;
    const throughput = megabytes / seconds;

    const target_throughput = if (builtin.mode == .Debug) 10.0 else 100.0;
    try std.testing.expect(throughput >= target_throughput);
}
