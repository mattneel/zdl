const std = @import("std");
const zdl = @import("zdl");
const format = zdl.format;
const Target = zdl.Target;

test "validateHeader succeeds for well-formed bytes" {
    var buf: [format.HEADER_SIZE]u8 = undefined;
    const header = format.Header{
        .magic = format.MAGIC,
        .version = 1,
        .target = 0,
        .reserved = .{ 0, 0, 0 },
        .length = 16,
        .checksum = 0xAABBCCDD,
    };

    format.writeHeader(header, &buf);
    const parsed = try format.validateHeader(&buf);
    try std.testing.expectEqualDeep(header, parsed);
}

test "validateHeader rejects bad magic" {
    var buf: [format.HEADER_SIZE]u8 = undefined;
    const header = format.Header{
        .magic = format.MAGIC,
        .version = 0,
        .target = 0,
        .reserved = .{ 0, 0, 0 },
        .length = 0,
        .checksum = 0,
    };

    format.writeHeader(header, &buf);
    buf[0] ^= 0xFF;
    try std.testing.expectError(format.FormatError.InvalidMagic, format.validateHeader(&buf));
}

test "validateHeader enforces maximum length" {
    var buf: [format.HEADER_SIZE]u8 = undefined;
    const header = format.Header{
        .magic = format.MAGIC,
        .version = 2,
        .target = 0,
        .reserved = .{ 0, 0, 0 },
        .length = format.MAX_DATA_SIZE + 1,
        .checksum = 0,
    };

    format.writeHeader(header, &buf);
    try std.testing.expectError(format.FormatError.DataTooLarge, format.validateHeader(&buf));
}

test "validateHeader rejects non-zero reserved bytes" {
    var buf: [format.HEADER_SIZE]u8 = undefined;
    const header = format.Header{
        .magic = format.MAGIC,
        .version = 3,
        .target = 0,
        .reserved = .{ 0, 0, 0 },
        .length = 4,
        .checksum = 0,
    };

    format.writeHeader(header, &buf);
    buf[10] = 1;
    try std.testing.expectError(format.FormatError.InvalidFormat, format.validateHeader(&buf));
}

test "validateHeader errors on short buffer" {
    var buf: [format.HEADER_SIZE - 1]u8 = [_]u8{0} ** (format.HEADER_SIZE - 1);
    try std.testing.expectError(format.FormatError.InvalidFormat, format.validateHeader(&buf));
}

const ArraySample = struct {
    value: u16,
    pub const zdl_config = .{ .version = 1 };
};

test "serializeArray encodes count and canonical payload" {
    const allocator = std.testing.allocator;
    const items = [_]ArraySample{
        .{ .value = 1 },
        .{ .value = 2 },
        .{ .value = 3 },
    };

    const bytes = try format.serializeArray(ArraySample, &items, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    const header_len = format.HEADER_SIZE;
    const header = try format.validateHeader(bytes[0..header_len]);
    try std.testing.expectEqual(@as(u64, items.len * @sizeOf(ArraySample)), header.length);

    const count = try format.arrayCount(bytes);
    try std.testing.expectEqual(@as(u64, items.len), count);

    const payload = bytes[header_len + 8 ..];
    var expected: [items.len]ArraySample = undefined;
    for (items, 0..) |item, idx| {
        expected[idx] = item;
    }
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected), payload);
}

test "arrayCount rejects truncated buffers" {
    const allocator = std.testing.allocator;
    const items = [_]ArraySample{.{ .value = 7 }};
    const bytes = try format.serializeArray(ArraySample, &items, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    try std.testing.expectError(format.FormatError.InvalidFormat, format.arrayCount(bytes[0 .. bytes.len - 4]));
}
