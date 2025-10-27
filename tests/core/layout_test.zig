const std = @import("std");
const zdl = @import("zdl");
const Target = zdl.Target;

const Inner = struct {
    a: u32,
    b: [2]f32,
};

const Sample = struct {
    id: u64,
    flag: bool,
    inner: Inner,
    values: [3]i16,
};

test "layout transform cpu <-> network round trip" {
    const allocator = std.testing.allocator;
    var sample = Sample{
        .id = 0x1122334455667788,
        .flag = true,
        .inner = .{
            .a = 0xAABBCCDD,
            .b = .{ 123.5, -98.75 },
        },
        .values = .{ -1, 2, 3 },
    };

    const cpu_bytes = std.mem.asBytes(&sample)[0..];
    const net_bytes = try zdl.layout.transform(Sample, cpu_bytes, Target.cpu, Target.network, allocator);
    defer allocator.free(net_bytes);

    const back_bytes = try zdl.layout.transform(Sample, net_bytes, Target.network, Target.cpu, allocator);
    defer allocator.free(back_bytes);

    try std.testing.expectEqualSlices(u8, cpu_bytes, back_bytes);
}

test "layout swap handles nested arrays" {
    var sample = Sample{
        .id = 0x1020304050607080,
        .flag = false,
        .inner = .{
            .a = 0x01020304,
            .b = .{ 1.0, 2.0 },
        },
        .values = .{ 10, 20, -30 },
    };

    var swapped: [@sizeOf(Sample)]u8 = undefined;
    zdl.layout.swapEndianness(Sample, std.mem.asBytes(&sample), swapped[0..]);

    var roundtrip: Sample = undefined;
    zdl.layout.swapEndianness(Sample, swapped[0..], std.mem.asBytes(&roundtrip));

    try std.testing.expectEqualDeep(sample, roundtrip);
}
