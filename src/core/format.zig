const std = @import("std");
const schema = @import("schema.zig");
const Target = @import("target.zig").Target;
const crc32 = @import("crc.zig");

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

pub const ArraySerializeError = error{
    UnsupportedTarget,
} || std.mem.Allocator.Error || FormatError;

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

pub fn serializeArray(
    comptime T: type,
    items: []const T,
    target: Target,
    allocator: std.mem.Allocator,
) ArraySerializeError![]const u8 {
    comptime schema.ensure(T);

    if (target != .cpu) {
        return error.UnsupportedTarget;
    }

    const item_size = @sizeOf(T);
    const item_size_u64 = std.math.cast(u64, item_size) orelse return FormatError.DataTooLarge;
    const count_u64 = std.math.cast(u64, items.len) orelse return FormatError.DataTooLarge;

    const items_bytes_u64 = std.math.mul(u64, item_size_u64, count_u64) catch return FormatError.DataTooLarge;
    if (items_bytes_u64 > MAX_DATA_SIZE) {
        return FormatError.DataTooLarge;
    }
    const items_bytes = std.math.cast(usize, items_bytes_u64) orelse return FormatError.InvalidFormat;

    const header_len = @as(usize, HEADER_SIZE);
    const total_len = std.math.add(usize, header_len + 8, items_bytes) catch return FormatError.DataTooLarge;

    const buffer = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buffer);

    writeIntLittle(u64, buffer[header_len..], 0, count_u64);

    var offset = header_len + 8;
    var index: usize = 0;
    while (index < items.len) : (index += 1) {
        const canonical = canonicalize(T, items[index]);
        const dest = buffer[offset .. offset + item_size];
        std.mem.copyForwards(u8, dest, std.mem.asBytes(&canonical));
        offset += item_size;
    }

    const items_slice = buffer[(header_len + 8)..(header_len + 8 + items_bytes)];
    const checksum = crc32.compute(items_slice);

    const header = Header{
        .magic = MAGIC,
        .version = schemaVersion(T),
        .target = @intFromEnum(target),
        .reserved = .{ 0, 0, 0 },
        .length = items_bytes_u64,
        .checksum = checksum,
    };

    writeHeader(header, buffer[0..header_len]);
    return buffer;
}

pub fn arrayCount(bytes: []const u8) FormatError!u64 {
    const header_len = @as(usize, HEADER_SIZE);
    if (bytes.len < header_len + 8) {
        return FormatError.InvalidFormat;
    }

    const header = try validateHeader(bytes[0..header_len]);
    const items_len = std.math.cast(usize, header.length) orelse return FormatError.InvalidFormat;
    const required_len = header_len + 8 + items_len;
    if (bytes.len < required_len) {
        return FormatError.InvalidFormat;
    }

    return readIntLittle(u64, bytes, header_len);
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

fn canonicalize(comptime T: type, value: T) T {
    return switch (@typeInfo(T)) {
        .bool, .int, .float => value,
        .array => |info| blk: {
            var result: T = undefined;
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                result[i] = canonicalize(info.child, value[i]);
            }
            break :blk result;
        },
        .@"struct" => |struct_info| blk: {
            var result: T = std.mem.zeroes(T);
            inline for (struct_info.fields) |field| {
                if (field.is_comptime) continue;
                @field(result, field.name) = canonicalize(field.type, @field(value, field.name));
            }
            break :blk result;
        },
        else => value,
    };
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
