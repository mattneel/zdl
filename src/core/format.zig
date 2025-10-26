const std = @import("std");

pub const Header = struct {
    magic: u32,
    version: u32,
    target: u8,
    reserved: [3]u8,
    length: u64,
    checksum: u32,
};

pub const MAGIC: u32 = 0x7A646C00;
pub const HEADER_SIZE: u32 = 24;
pub const MAX_DATA_SIZE: u64 = 1024 * 1024 * 1024;

pub const FormatError = error{
    InvalidMagic,
    DataTooLarge,
    InvalidFormat,
};

pub fn validateHeader(bytes: []const u8) FormatError!Header {
    const header_len = @as(usize, HEADER_SIZE);
    if (bytes.len < header_len) {
        return FormatError.InvalidFormat;
    }

    const magic = readIntLittle(u32, bytes, 0);
    if (magic != MAGIC) {
        return FormatError.InvalidMagic;
    }

    const version = readIntLittle(u32, bytes, 4);
    const target = bytes[8];

    const reserved_slice = bytes[9..12];
    if (!std.mem.allEqual(u8, reserved_slice, 0)) {
        return FormatError.InvalidFormat;
    }

    const length = readIntLittle(u64, bytes, 12);
    if (length > MAX_DATA_SIZE) {
        return FormatError.DataTooLarge;
    }

    const checksum = readIntLittle(u32, bytes, 20);

    return Header{
        .magic = magic,
        .version = version,
        .target = target,
        .reserved = .{ 0, 0, 0 },
        .length = length,
        .checksum = checksum,
    };
}

pub fn writeHeader(header: Header, buf: []u8) void {
    const header_len = @as(usize, HEADER_SIZE);
    std.debug.assert(buf.len >= header_len);
    std.debug.assert(std.mem.allEqual(u8, header.reserved[0..], 0));

    writeIntLittle(u32, buf, 0, header.magic);
    writeIntLittle(u32, buf, 4, header.version);
    buf[8] = header.target;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 0;
    writeIntLittle(u64, buf, 12, header.length);
    writeIntLittle(u32, buf, 20, header.checksum);
}

fn readIntLittle(comptime T: type, bytes: []const u8, offset: usize) T {
    const byte_count = @divExact(@typeInfo(T).int.bits, 8);
    const size = @as(usize, byte_count);
    const slice = bytes[offset .. offset + size];
    const ptr: *const [byte_count]u8 = @ptrCast(slice.ptr);
    return std.mem.readInt(T, ptr, .little);
}

fn writeIntLittle(comptime T: type, buf: []u8, offset: usize, value: T) void {
    const size = @as(usize, @divExact(@typeInfo(T).int.bits, 8));
    var v = @as(@TypeOf(value), value);
    var i: usize = 0;
    while (i < size) : (i += 1) {
        buf[offset + i] = @intCast(v & 0xFF);
        v >>= 8;
    }
}

test "writeHeader writes checksum" {
    var buf = [_]u8{0xAA} ** HEADER_SIZE;
    const header = Header{
        .magic = MAGIC,
        .version = 1,
        .target = 0,
        .reserved = .{ 0, 0, 0 },
        .length = 16,
        .checksum = 0x12345678,
    };
    writeHeader(header, &buf);
    try std.testing.expectEqual(@as(u8, 0x78), buf[20]);
    try std.testing.expectEqual(@as(u8, 0x56), buf[21]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[22]);
    try std.testing.expectEqual(@as(u8, 0x12), buf[23]);
}
