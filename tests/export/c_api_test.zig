const std = @import("std");
const testing = std.testing;
const zdl = @import("zdl");
const c_api = zdl.interop.c_api;
const Target = zdl.Target;

const Sample = struct {
    id: u64,
    value: f32,
    name: [8]u8,

    pub const zdl_config = .{ .version = 1 };
};

test "C exports serialize and deserialize round trip" {
    var sample = Sample{
        .id = 99,
        .value = 42.5,
        .name = [_]u8{ 'z', 'd', 'l', 0, 0, 0, 0, 0 },
    };

    var out_len: usize = 0;
    const target_value: c_int = @intCast(@intFromEnum(Target.cpu));
    const bytes_ptr = c_api.serializeForType(Sample, &sample, target_value, &out_len);
    try testing.expect(bytes_ptr != null);
    try testing.expect(out_len > 0);

    const decoded_ptr = c_api.deserializeForType(Sample, bytes_ptr, out_len);
    try testing.expect(decoded_ptr != null);
    try testing.expectEqual(sample.id, decoded_ptr.?.*.id);
    try testing.expectApproxEqAbs(sample.value, decoded_ptr.?.*.value, 0.0001);

    c_api.freeAlloc(@ptrCast(decoded_ptr.?));
    c_api.freeAlloc(@ptrCast(bytes_ptr.?));
}

test "serialize array and count helper return data" {
    var items = [_]Sample{
        .{
            .id = 1,
            .value = 1.0,
            .name = [_]u8{ 'a', 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .id = 2,
            .value = 2.0,
            .name = [_]u8{ 'b', 0, 0, 0, 0, 0, 0, 0 },
        },
    };

    var out_len: usize = 0;
    const bytes_ptr = c_api.serializeArrayForType(Sample, items[0..].ptr, items.len, @intCast(@intFromEnum(Target.cpu)), &out_len);
    try testing.expect(bytes_ptr != null);
    try testing.expect(out_len > 0);

    const count = c_api.arrayCountFromBytes(bytes_ptr, out_len);
    try testing.expectEqual(@as(u64, items.len), count);

    c_api.freeAlloc(@ptrCast(bytes_ptr.?));
}

test "invalid target returns null pointer" {
    var sample = Sample{
        .id = 1,
        .value = 1.0,
        .name = [_]u8{0} ** 8,
    };

    var out_len: usize = 0;
    const invalid_target: c_int = @intCast(@intFromEnum(Target.cuda));
    const bytes_ptr = c_api.serializeForType(Sample, &sample, invalid_target, &out_len);
    try testing.expect(bytes_ptr == null);
}
