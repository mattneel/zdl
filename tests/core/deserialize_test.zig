const std = @import("std");
const zdl = @import("zdl");

const Target = zdl.Target;
const serializer = zdl.serialize;
const deserializer = zdl.deserialize;
const format = zdl.format;

test "deserialize reconstructs struct from serialized bytes" {
    const gpa = std.testing.allocator;
    const Sample = struct {
        a: u32,
        b: bool,
        pub const zdl_config = .{ .version = 2 };
    };

    const original = Sample{ .a = 1234, .b = true };
    const bytes = try serializer.serialize(original, Target.cpu, gpa);
    defer gpa.free(@constCast(bytes));

    const parsed = try deserializer.deserialize(Sample, bytes, gpa);
    try std.testing.expectEqualDeep(original, parsed);
}

test "deserialize rejects non CPU targets" {
    const gpa = std.testing.allocator;
    const Sample = struct { value: u16 };
    const original = Sample{ .value = 9 };
    const bytes = try serializer.serialize(original, Target.cpu, gpa);
    defer gpa.free(@constCast(bytes));

    const mut = try gpa.dupe(u8, bytes);
    defer gpa.free(mut);
    mut[8] = 1; // toggle target

    const result = deserializer.deserialize(Sample, mut, gpa);
    try std.testing.expectError(deserializer.DeserializeError.UnsupportedTarget, result);
}

test "deserialize detects checksum mismatch" {
    const gpa = std.testing.allocator;
    const Sample = struct { value: u32 };
    const bytes = try serializer.serialize(Sample{ .value = 0x12345678 }, Target.cpu, gpa);
    defer gpa.free(@constCast(bytes));

    const mut = try gpa.dupe(u8, bytes);
    defer gpa.free(mut);
    const header_len = @as(usize, format.HEADER_SIZE);
    mut[header_len] ^= 0xFF;

    const result = deserializer.deserialize(Sample, mut, gpa);
    try std.testing.expectError(deserializer.DeserializeError.ChecksumMismatch, result);
}

test "deserialize enforces length match" {
    const gpa = std.testing.allocator;
    const Sample = struct { value: u16 };
    const bytes = try serializer.serialize(Sample{ .value = 1 }, Target.cpu, gpa);
    defer gpa.free(@constCast(bytes));

    const mut = try gpa.dupe(u8, bytes);
    defer gpa.free(mut);
    // decrement length field in header
    const length_offset = 12;
    mut[length_offset] -%= 1;

    const result = deserializer.deserialize(Sample, mut, gpa);
    try std.testing.expectError(deserializer.DeserializeError.LengthMismatch, result);
}

test "deserialize errors on truncated payload" {
    const gpa = std.testing.allocator;
    const Sample = struct { value: u32 };
    const bytes = try serializer.serialize(Sample{ .value = 2 }, Target.cpu, gpa);
    defer gpa.free(@constCast(bytes));

    const truncated_len = bytes.len - 1;
    const truncated = bytes[0..truncated_len];

    const result = deserializer.deserialize(Sample, truncated, gpa);
    try std.testing.expectError(deserializer.DeserializeError.TruncatedPayload, result);
}
