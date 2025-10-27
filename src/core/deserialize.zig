const std = @import("std");
const format = @import("format.zig");
const schema = @import("schema.zig");
const Target = @import("target.zig").Target;
const layout = @import("layout.zig");
const crc32 = @import("crc.zig");

pub const DeserializeError = error{
    UnsupportedTarget,
    SizeMismatch,
    ChecksumMismatch,
    TruncatedData,
    ExtraData,
} || format.FormatError;

pub fn deserialize(
    comptime T: type,
    bytes: []const u8,
    allocator: std.mem.Allocator,
) DeserializeError!T {
    _ = allocator;
    comptime schema.ensure(T);

    const header_len = @as(usize, format.HEADER_SIZE);
    if (bytes.len < header_len) {
        return format.FormatError.InvalidFormat;
    }

    const header = try format.validateHeader(bytes[0..header_len]);

    const stored_target = std.meta.intToEnum(Target, header.target) catch return error.UnsupportedTarget;
    if (stored_target == .cuda or stored_target == .metal) {
        return error.UnsupportedTarget;
    }

    const payload_len = std.math.cast(usize, header.length) orelse return error.SizeMismatch;
    if (payload_len != @sizeOf(T)) {
        return error.SizeMismatch;
    }

    const aligned_payload_len = std.mem.alignForward(usize, payload_len, @as(usize, stored_target.alignment()));
    const expected_total_len = header_len + aligned_payload_len;
    if (bytes.len < expected_total_len) {
        return error.TruncatedData;
    }
    if (bytes.len > expected_total_len) {
        return error.ExtraData;
    }

    const payload = bytes[header_len .. header_len + payload_len];
    const checksum = crc32.compute(payload);
    if (checksum != header.checksum) {
        return error.ChecksumMismatch;
    }

    var result: T = undefined;
    const result_bytes = std.mem.asBytes(&result);
    if (stored_target.needsEndianSwap()) {
        layout.swapEndianness(T, payload, result_bytes);
    } else {
        std.mem.copyForwards(u8, result_bytes, payload);
    }

    return result;
}
