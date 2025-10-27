const std = @import("std");
const format = @import("format.zig");
const schema = @import("schema.zig");
const Target = @import("target.zig").Target;
const crc32 = @import("crc.zig");

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

    if (target == .cuda or target == .metal) {
        return error.UnsupportedTarget;
    }

    const header_len = @as(usize, format.HEADER_SIZE);
    const payload_len = @sizeOf(T);
    const alignment = @as(usize, target.alignment());
    const aligned_payload_len = std.mem.alignForward(usize, payload_len, if (alignment == 0) 1 else alignment);

    const payload_len_u64 = std.math.cast(u64, payload_len) orelse return format.FormatError.DataTooLarge;
    const aligned_payload_len_u64 = std.math.cast(u64, aligned_payload_len) orelse return format.FormatError.DataTooLarge;
    if (aligned_payload_len_u64 > format.MAX_DATA_SIZE) {
        return format.FormatError.DataTooLarge;
    }

    const total_len = header_len + aligned_payload_len;
    const buffer = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buffer);

    const payload_dst = buffer[header_len..];
    @memset(payload_dst, 0);

    const payload_bytes = payload_dst[0..payload_len];

    inline for (std.meta.fields(T)) |field| {
        if (field.is_comptime) continue;
        const field_offset = @offsetOf(T, field.name);
        const field_value = @field(value, field.name);

        if (target.needsEndianSwap()) {
            writeFieldWithEndianSwap(field.type, payload_bytes, field_offset, field_value);
        } else {
            writeFieldCanonical(field.type, payload_bytes, field_offset, field_value);
        }
    }

    const checksum = crc32.compute(payload_bytes);

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

fn writeFieldCanonical(comptime F: type, buf: []u8, offset: usize, value: anytype) void {
    switch (@typeInfo(F)) {
        .bool => {
            const b: bool = value;
            buf[offset] = if (b) 1 else 0;
        },
        .int => |info| {
            var tmp: F = value;
            const size = @divExact(info.bits, 8);
            std.mem.copyForwards(u8, buf[offset .. offset + size], std.mem.asBytes(&tmp));
        },
        .float => |info| {
            var tmp: F = value;
            const size = @divExact(info.bits, 8);
            std.mem.copyForwards(u8, buf[offset .. offset + size], std.mem.asBytes(&tmp));
        },
        .array => |info| {
            const elem_size = @sizeOf(info.child);
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                writeFieldCanonical(info.child, buf, offset + i * elem_size, value[i]);
            }
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                if (field.is_comptime) continue;
                const sub_offset = offset + @offsetOf(F, field.name);
                writeFieldCanonical(field.type, buf, sub_offset, @field(value, field.name));
            }
        },
        else => @compileError("Unsupported field type for serialization"),
    }
}

fn writeFieldWithEndianSwap(comptime F: type, buf: []u8, offset: usize, value: anytype) void {
    writeFieldCanonical(F, buf, offset, value);
    swapFieldInPlace(F, buf, offset);
}

fn swapFieldInPlace(comptime F: type, buf: []u8, offset: usize) void {
    switch (@typeInfo(F)) {
        .bool => {},
        .int => |info| {
            if (info.bits > 8) {
                const size = @divExact(info.bits, 8);
                std.mem.reverse(u8, buf[offset .. offset + size]);
            }
        },
        .float => |info| {
            const size = @divExact(info.bits, 8);
            std.mem.reverse(u8, buf[offset .. offset + size]);
        },
        .array => |info| {
            const elem_size = @sizeOf(info.child);
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                swapFieldInPlace(info.child, buf, offset + i * elem_size);
            }
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                if (field.is_comptime) continue;
                const sub_offset = offset + @offsetOf(F, field.name);
                swapFieldInPlace(field.type, buf, sub_offset);
            }
        },
        else => @compileError("Unsupported field type for endian swap"),
    }
}
