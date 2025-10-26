const std = @import("std");
const zdl = @import("zdl");
const format = zdl.format;

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
