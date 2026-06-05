const std = @import("std");
const format = @import("format.zig");
const schema = @import("schema.zig");
const Target = @import("target.zig").Target;
const crc32 = @import("crc.zig");

pub const SerializeError = error{
    UnsupportedTarget,
} || std.mem.Allocator.Error || format.FormatError;

pub const SerializeIntoError = error{
    UnsupportedTarget,
    BufferTooSmall,
} || format.FormatError;

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

    const total_len = try checkedTotalLen(T, target);
    const buffer = try allocator.alloc(u8, total_len);

    writeRecord(T, buffer, value, target);
    return buffer;
}

/// Zero-allocation variant of `serialize`: writes the record into `dest` and
/// returns the written sub-slice. `dest` must be at least
/// `serializedSize(@TypeOf(value), target)` bytes.
pub fn serializeInto(
    dest: []u8,
    value: anytype,
    target: Target,
) SerializeIntoError![]u8 {
    const T = @TypeOf(value);
    comptime schema.ensure(T);

    if (target == .cuda or target == .metal) {
        return error.UnsupportedTarget;
    }

    const total_len = try checkedTotalLen(T, target);
    if (dest.len < total_len) {
        return error.BufferTooSmall;
    }

    const buffer = dest[0..total_len];
    writeRecord(T, buffer, value, target);
    return buffer;
}

/// Number of bytes `serialize`/`serializeInto` produce for `T` at `target`:
/// header plus the alignment-padded payload.
pub fn serializedSize(comptime T: type, target: Target) usize {
    const alignment = @as(usize, target.alignment());
    const aligned_payload_len = std.mem.alignForward(usize, @sizeOf(T), if (alignment == 0) 1 else alignment);
    return @as(usize, format.HEADER_SIZE) + aligned_payload_len;
}

fn checkedTotalLen(comptime T: type, target: Target) format.FormatError!usize {
    const total_len = serializedSize(T, target);
    const aligned_payload_len = total_len - @as(usize, format.HEADER_SIZE);

    const aligned_payload_len_u64 = std.math.cast(u64, aligned_payload_len) orelse return format.FormatError.DataTooLarge;
    if (aligned_payload_len_u64 > format.MAX_DATA_SIZE) {
        return format.FormatError.DataTooLarge;
    }

    return total_len;
}

fn writeRecord(comptime T: type, buffer: []u8, value: T, target: Target) void {
    const header_len = @as(usize, format.HEADER_SIZE);
    const payload_len = @sizeOf(T);
    const payload_dst = buffer[header_len..];
    const payload_bytes = payload_dst[0..payload_len];

    if (target.needsEndianSwap()) {
        @memset(payload_dst, 0);
        inline for (std.meta.fields(T)) |field| {
            if (field.is_comptime) continue;
            const field_offset = @offsetOf(T, field.name);
            writeFieldWithEndianSwap(field.type, payload_bytes, field_offset, @field(value, field.name));
        }
    } else if (comptime isBulkCopyable(T)) {
        // No padding anywhere in T: its in-memory bytes are exactly the
        // canonical wire bytes, so one bulk copy is deterministic.
        @memcpy(payload_bytes, std.mem.asBytes(&value));
        @memset(payload_dst[payload_len..], 0);
    } else {
        @memset(payload_dst, 0);
        inline for (std.meta.fields(T)) |field| {
            if (field.is_comptime) continue;
            const field_offset = @offsetOf(T, field.name);
            writeFieldCanonical(field.type, payload_bytes, field_offset, @field(value, field.name));
        }
    }

    const checksum = crc32.compute(payload_bytes);

    const header = format.Header{
        .magic = format.MAGIC,
        .version = schemaVersion(T),
        .target = @intFromEnum(target),
        .reserved = .{ 0, 0, 0 },
        .length = @as(u64, payload_len),
        .checksum = checksum,
    };

    format.writeHeader(header, buffer[0..header_len]);
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

/// True when F's in-memory representation is byte-for-byte its canonical wire
/// form: no padding anywhere, no normalization (bool -> 0/1), and no
/// truncation (e.g. u24 occupies 4 bytes in memory but 3 on the wire).
/// Such types can be marshaled with a single @memcpy.
fn isBulkCopyable(comptime F: type) bool {
    return switch (@typeInfo(F)) {
        // bool is normalized to exactly 0/1 on the wire; keep the explicit path.
        .bool => false,
        .int => |info| @sizeOf(F) * 8 == info.bits,
        .float => |info| @sizeOf(F) * 8 == info.bits,
        .array => |info| isBulkCopyable(info.child),
        .@"struct" => |struct_info| blk: {
            var covered: usize = 0;
            for (struct_info.fields) |field| {
                if (field.is_comptime) continue;
                if (!isBulkCopyable(field.type)) break :blk false;
                covered += @sizeOf(field.type);
            }
            // Fields never overlap, so full coverage means no padding.
            break :blk covered == @sizeOf(F);
        },
        else => false,
    };
}

fn writeFieldCanonical(comptime F: type, buf: []u8, offset: usize, value: anytype) void {
    if (comptime isBulkCopyable(F)) {
        @memcpy(buf[offset..][0..@sizeOf(F)], std.mem.asBytes(&value));
        return;
    }
    switch (@typeInfo(F)) {
        .bool => {
            const b: bool = value;
            buf[offset] = if (b) 1 else 0;
        },
        .int => |info| {
            var tmp: F = value;
            const size = @divExact(info.bits, 8);
            std.mem.copyForwards(u8, buf[offset .. offset + size], std.mem.asBytes(&tmp)[0..size]);
        },
        .float => |info| {
            var tmp: F = value;
            const size = @divExact(info.bits, 8);
            std.mem.copyForwards(u8, buf[offset .. offset + size], std.mem.asBytes(&tmp)[0..size]);
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
