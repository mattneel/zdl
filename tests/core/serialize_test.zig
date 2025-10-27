const std = @import("std");
const zdl = @import("zdl");

const format = zdl.format;
const Target = zdl.Target;
const serializer = zdl.serialize;

test "serialize emits header and payload for CPU target" {
    const gpa = std.testing.allocator;
    const Sample = struct {
        id: u64,
        active: bool,
        scale: f32,
        pub const zdl_config = .{ .version = 7 };
    };

    const value = Sample{
        .id = 0xDEADBEEF,
        .active = true,
        .scale = 1.5,
    };

    const bytes = try serializer.serialize(value, Target.cpu, gpa);
    defer gpa.free(@constCast(bytes));

    const header_len = @as(usize, format.HEADER_SIZE);
    const header_bytes = bytes[0..header_len];
    const payload_len = @sizeOf(Sample);
    const aligned_payload_len = std.mem.alignForward(usize, payload_len, Target.cpu.alignment());
    const payload_bytes = bytes[header_len .. header_len + aligned_payload_len];
    const data_bytes = payload_bytes[0..payload_len];

    const header = try format.validateHeader(header_bytes);
    if (header.checksum != std.hash.crc.Crc32.hash(data_bytes)) {
        std.debug.print("header bytes: ", .{});
        for (header_bytes) |byte| std.debug.print("{X:0>2}", .{byte});
        std.debug.print("\n", .{});
    }
    try std.testing.expectEqual(format.MAGIC, header.magic);
    try std.testing.expectEqual(@as(u32, 7), header.version);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Target.cpu)), header.target);
    try std.testing.expectEqual(@as(u64, payload_len), header.length);
    const expected_checksum = std.hash.crc.Crc32.hash(data_bytes);
    const computed_checksum = zdl.crc.compute(data_bytes);
    try std.testing.expectEqual(expected_checksum, header.checksum);
    try std.testing.expectEqual(expected_checksum, computed_checksum);
    if (aligned_payload_len > payload_len) {
        const padding = payload_bytes[payload_len..];
        for (padding) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "serialize supports disk target" {
    const gpa = std.testing.allocator;
    const Sample = struct {
        value: u32,
    };

    const bytes = try serializer.serialize(Sample{ .value = 1 }, Target.disk, gpa);
    defer gpa.free(@constCast(bytes));

    const expected_len = @as(usize, format.HEADER_SIZE) +
        std.mem.alignForward(usize, @sizeOf(Sample), Target.disk.alignment());
    try std.testing.expectEqual(expected_len, bytes.len);
}

test "crc sanity with testing allocator" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 16);
    defer gpa.free(buf);
    const sample = [_]u8{ 0xef, 0xbe, 0xad, 0xde, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x3f, 0x01, 0x00, 0x00, 0x00 };
    std.mem.copyForwards(u8, buf, &sample);
    const expected = std.hash.crc.Crc32.hash(buf);
    try std.testing.expectEqual(expected, zdl.crc.compute(buf));
}
