const std = @import("std");
const Target = @import("target.zig").Target;

pub const LayoutError = error{InvalidLength} || std.mem.Allocator.Error;

/// Transform data from one target layout to another without headers.
pub fn transform(
    comptime T: type,
    source_bytes: []const u8,
    source_target: Target,
    dest_target: Target,
    allocator: std.mem.Allocator,
) LayoutError![]u8 {
    if (source_bytes.len < @sizeOf(T)) {
        return LayoutError.InvalidLength;
    }

    if (source_target == dest_target) {
        return try allocator.dupe(u8, source_bytes[0..@sizeOf(T)]);
    }

    const value = try deserializeRaw(T, source_bytes, source_target);
    return try serializeRaw(T, value, dest_target, allocator);
}

fn deserializeRaw(
    comptime T: type,
    bytes: []const u8,
    target: Target,
) LayoutError!T {
    if (bytes.len < @sizeOf(T)) {
        return LayoutError.InvalidLength;
    }

    var value: T = undefined;
    const dst = std.mem.asBytes(&value);
    @memset(dst, 0);

    if (target.needsEndianSwap()) {
        swapEndianness(T, bytes, dst);
    } else {
        std.mem.copyForwards(u8, dst, bytes[0..@sizeOf(T)]);
    }

    return value;
}

fn serializeRaw(
    comptime T: type,
    value: T,
    target: Target,
    allocator: std.mem.Allocator,
) LayoutError![]u8 {
    const size = @sizeOf(T);
    const buf = try allocator.alloc(u8, size);
    @memset(buf, 0);

    const value_bytes = std.mem.asBytes(&value);
    if (target.needsEndianSwap()) {
        swapEndianness(T, value_bytes, buf);
    } else {
        std.mem.copyForwards(u8, buf, value_bytes);
    }

    return buf;
}

/// Swap endianness for all multi-byte fields in T from src into dst.
pub fn swapEndianness(comptime T: type, src: []const u8, dst: []u8) void {
    const size = @sizeOf(T);
    std.debug.assert(src.len >= size);
    std.debug.assert(dst.len >= size);

    swapField(T, src, dst, 0);
}

fn swapField(comptime F: type, src: []const u8, dst: []u8, offset: usize) void {
    switch (@typeInfo(F)) {
        .bool => dst[offset] = src[offset],
        .int => |info| {
            if (info.bits == 8) {
                dst[offset] = src[offset];
            } else {
                const byte_count = @divExact(info.bits, 8);
                var i: usize = 0;
                while (i < byte_count) : (i += 1) {
                    dst[offset + i] = src[offset + byte_count - 1 - i];
                }
            }
        },
        .float => |info| {
            const IntType = std.meta.Int(.unsigned, info.bits);
            swapField(IntType, src, dst, offset);
        },
        .array => |info| {
            const elem_size = @sizeOf(info.child);
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                swapField(info.child, src, dst, offset + i * elem_size);
            }
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                if (field.is_comptime) continue;
                const field_offset = offset + @offsetOf(F, field.name);
                swapField(field.type, src, dst, field_offset);
            }
        },
        else => @compileError("Unsupported field type for endian swap"),
    }
}
