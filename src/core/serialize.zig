const std = @import("std");
const format = @import("format.zig");
const schema = @import("schema.zig");
const Target = @import("target.zig").Target;
const crc32 = @import("crc.zig");
const builtin = @import("builtin");

pub const SerializeError = error{
    UnsupportedTarget,
} || std.mem.Allocator.Error || format.FormatError;

pub fn serialize(
    value: anytype,
    target: Target,
    allocator: std.mem.Allocator,
) SerializeError![]const u8 {
    const T = @TypeOf(value);
    comptime schema.ensure(T);

    if (target != .cpu) {
        return error.UnsupportedTarget;
    }

    const header_len = @as(usize, format.HEADER_SIZE);
    const payload_len = @sizeOf(T);
    const payload_len_u64 = std.math.cast(u64, payload_len) orelse return format.FormatError.DataTooLarge;
    if (payload_len_u64 > format.MAX_DATA_SIZE) {
        return format.FormatError.DataTooLarge;
    }

    const total_len = std.math.add(usize, header_len, payload_len) catch return format.FormatError.DataTooLarge;
    const buffer = try allocator.alloc(u8, total_len);

    const payload_dst = buffer[header_len..];
    const canonical = canonicalize(T, value);
    std.mem.copyForwards(u8, payload_dst, std.mem.asBytes(&canonical));

    const checksum = crc32.compute(payload_dst);

    const header = format.Header{
        .magic = format.MAGIC,
        .version = schemaVersion(T),
        .target = @intFromEnum(target),
        .reserved = .{ 0, 0, 0 },
        .length = payload_len_u64,
        .checksum = checksum,
    };

    format.writeHeader(header, buffer[0..header_len]);
    return buffer;
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
