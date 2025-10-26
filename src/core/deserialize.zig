const std = @import("std");
const format = @import("format.zig");
const schema = @import("schema.zig");
const Target = @import("target.zig").Target;
const crc32 = @import("crc.zig");

pub const DeserializeError = error{
    UnsupportedTarget,
    LengthMismatch,
    ChecksumMismatch,
    TruncatedPayload,
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

    if (header.target != @intFromEnum(Target.cpu)) {
        return error.UnsupportedTarget;
    }

    const expected_len = @sizeOf(T);
    const expected_len_u64 = std.math.cast(u64, expected_len) orelse return error.LengthMismatch;
    if (header.length != expected_len_u64) {
        return error.LengthMismatch;
    }

    const total_len = std.math.add(usize, header_len, expected_len) catch return error.TruncatedPayload;
    if (bytes.len < total_len) {
        return error.TruncatedPayload;
    }
    if (bytes.len > total_len) {
        return error.ExtraData;
    }

    const payload = bytes[header_len..total_len];
    const checksum = crc32.compute(payload);
    if (checksum != header.checksum) {
        return error.ChecksumMismatch;
    }

    var result: T = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&result), payload);
    return result;
}
