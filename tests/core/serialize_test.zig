const std = @import("std");
const zdl = @import("zdl");

const format = zdl.format;
const Target = zdl.Target;
const serializer = zdl.serialize;

test "serialize emits header and payload for CPU target" {
    const gpa = std.testing.allocator;
    const Sample = struct {
        id: u64,
        active: bool,
        scale: f32,
        pub const zdl_config = .{ .version = 7 };
    };

    const value = Sample{
        .id = 0xDEADBEEF,
        .active = true,
        .scale = 1.5,
    };

    const bytes = try serializer.serialize(value, Target.cpu, gpa);
    defer gpa.free(@constCast(bytes));

    const header_len = @as(usize, format.HEADER_SIZE);
    const header_bytes = bytes[0..header_len];
    const payload_len = @sizeOf(Sample);
    const aligned_payload_len = std.mem.alignForward(usize, payload_len, Target.cpu.alignment());
    const payload_bytes = bytes[header_len .. header_len + aligned_payload_len];
    const data_bytes = payload_bytes[0..payload_len];

    const header = try format.validateHeader(header_bytes);
    if (header.checksum != std.hash.crc.Crc32.hash(data_bytes)) {
        std.debug.print("header bytes: ", .{});
        for (header_bytes) |byte| std.debug.print("{X:0>2}", .{byte});
        std.debug.print("\n", .{});
    }
    try std.testing.expectEqual(format.MAGIC, header.magic);
    try std.testing.expectEqual(@as(u32, 7), header.version);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Target.cpu)), header.target);
    try std.testing.expectEqual(@as(u64, payload_len), header.length);
    const expected_checksum = std.hash.crc.Crc32.hash(data_bytes);
    const computed_checksum = zdl.crc.compute(data_bytes);
    try std.testing.expectEqual(expected_checksum, header.checksum);
    try std.testing.expectEqual(expected_checksum, computed_checksum);
    if (aligned_payload_len > payload_len) {
        const padding = payload_bytes[payload_len..];
        for (padding) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "serialize supports disk target" {
    const gpa = std.testing.allocator;
    const Sample = struct {
        value: u32,
    };

    const bytes = try serializer.serialize(Sample{ .value = 1 }, Target.disk, gpa);
    defer gpa.free(@constCast(bytes));

    const expected_len = @as(usize, format.HEADER_SIZE) +
        std.mem.alignForward(usize, @sizeOf(Sample), Target.disk.alignment());
    try std.testing.expectEqual(expected_len, bytes.len);
}

test "serializeInto matches serialize output byte for byte" {
    const gpa = std.testing.allocator;
    const Sample = struct {
        id: u64,
        data: [100]u8,
        pub const zdl_config = .{ .version = 3 };
    };
    const value = Sample{
        .id = 0x0123456789ABCDEF,
        .data = [_]u8{0xAB} ** 100,
    };

    const heap_bytes = try serializer.serialize(value, Target.cpu, gpa);
    defer gpa.free(@constCast(heap_bytes));

    var buf: [serializer.serializedSize(Sample, Target.cpu)]u8 = undefined;
    const into_bytes = try serializer.serializeInto(&buf, value, Target.cpu);

    try std.testing.expectEqualSlices(u8, heap_bytes, into_bytes);
}

test "serializeInto matches serialize output for network target" {
    const gpa = std.testing.allocator;
    const Sample = struct {
        id: u64,
        scale: f32,
        active: bool,
        pub const zdl_config = .{ .version = 2 };
    };
    const value = Sample{ .id = 0xCAFEBABE, .scale = 2.5, .active = true };

    const heap_bytes = try serializer.serialize(value, Target.network, gpa);
    defer gpa.free(@constCast(heap_bytes));

    var buf: [serializer.serializedSize(Sample, Target.network)]u8 = undefined;
    const into_bytes = try serializer.serializeInto(&buf, value, Target.network);

    try std.testing.expectEqualSlices(u8, heap_bytes, into_bytes);
}

test "serializeInto roundtrips through deserialize" {
    const Sample = struct {
        id: u64,
        scale: f32,
        flags: [4]u8,
        pub const zdl_config = .{ .version = 2 };
    };
    const value = Sample{ .id = 42, .scale = 2.5, .flags = .{ 1, 2, 3, 4 } };

    var buf: [serializer.serializedSize(Sample, Target.cpu)]u8 = undefined;
    const bytes = try serializer.serializeInto(&buf, value, Target.cpu);

    const result = try zdl.deserialize.deserialize(Sample, bytes, std.testing.allocator);
    try std.testing.expectEqual(value, result);
}

test "serializeInto rejects undersized buffer" {
    const Sample = struct {
        value: u32,
    };
    var buf: [serializer.serializedSize(Sample, Target.cpu) - 1]u8 = undefined;
    try std.testing.expectError(
        error.BufferTooSmall,
        serializer.serializeInto(&buf, Sample{ .value = 1 }, Target.cpu),
    );
}

test "padded struct serializes deterministically into a poisoned buffer" {
    const gpa = std.testing.allocator;
    const Padded = struct {
        flag: u8,
        id: u64, // struct has 7 bytes of internal padding
        pub const zdl_config = .{ .version = 1 };
    };
    const value = Padded{ .flag = 1, .id = 2 };

    const a = try serializer.serialize(value, Target.cpu, gpa);
    defer gpa.free(@constCast(a));
    const b = try serializer.serialize(value, Target.cpu, gpa);
    defer gpa.free(@constCast(b));
    try std.testing.expectEqualSlices(u8, a, b);

    // Stale bytes in the destination must not leak into the record: padding
    // is required to serialize as zero regardless of buffer contents.
    var buf: [serializer.serializedSize(Padded, Target.cpu)]u8 = undefined;
    @memset(&buf, 0xFF);
    const c = try serializer.serializeInto(&buf, value, Target.cpu);
    try std.testing.expectEqualSlices(u8, a, c);
}

test "bulk-copyable struct serializes deterministically into a poisoned buffer" {
    const gpa = std.testing.allocator;
    // No padding anywhere: takes the whole-struct @memcpy fast path. The
    // alignment tail (serializedSize - HEADER_SIZE - sizeOf) must still be
    // zeroed even when the destination holds stale bytes.
    const Packed = struct {
        a: u64,
        b: u64,
        pub const zdl_config = .{ .version = 1 };
    };
    const value = Packed{ .a = 0x1111111111111111, .b = 0x2222222222222222 };

    const heap_bytes = try serializer.serialize(value, Target.cpu, gpa);
    defer gpa.free(@constCast(heap_bytes));

    var buf: [serializer.serializedSize(Packed, Target.cpu)]u8 = undefined;
    @memset(&buf, 0xFF);
    const into_bytes = try serializer.serializeInto(&buf, value, Target.cpu);
    try std.testing.expectEqualSlices(u8, heap_bytes, into_bytes);

    const tail = into_bytes[@as(usize, format.HEADER_SIZE) + @sizeOf(Packed) ..];
    try std.testing.expect(tail.len > 0); // this type must actually have a tail
    for (tail) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "serializeInto rejects unsupported targets" {
    const Sample = struct {
        value: u32,
    };
    var buf: [256]u8 = undefined;
    try std.testing.expectError(
        error.UnsupportedTarget,
        serializer.serializeInto(&buf, Sample{ .value = 1 }, Target.cuda),
    );
    try std.testing.expectError(
        error.UnsupportedTarget,
        serializer.serializeInto(&buf, Sample{ .value = 1 }, Target.metal),
    );
}

test "serializedSize matches produced record length" {
    const gpa = std.testing.allocator;
    const Sample = struct {
        id: u64,
        data: [100]u8,
        pub const zdl_config = .{ .version = 1 };
    };
    inline for (.{ Target.cpu, Target.disk, Target.network }) |target| {
        const bytes = try serializer.serialize(Sample{ .id = 1, .data = [_]u8{0} ** 100 }, target, gpa);
        defer gpa.free(@constCast(bytes));
        try std.testing.expectEqual(serializer.serializedSize(Sample, target), bytes.len);
    }
}

test "crc sanity with testing allocator" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 16);
    defer gpa.free(buf);
    const sample = [_]u8{ 0xef, 0xbe, 0xad, 0xde, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x3f, 0x01, 0x00, 0x00, 0x00 };
    std.mem.copyForwards(u8, buf, &sample);
    const expected = std.hash.crc.Crc32.hash(buf);
    try std.testing.expectEqual(expected, zdl.crc.compute(buf));
}
