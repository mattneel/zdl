const std = @import("std");
const testing = std.testing;
const zdl = @import("zdl");
const c_api = zdl.interop.c_api;
const c_error = zdl.interop.c_error;
const Target = zdl.Target;
const format = zdl.format;

const Sample = struct {
    id: u64,
    value: f32,
    name: [8]u8,

    pub const zdl_config = .{ .version = 1 };
};

test "C exports serialize and deserialize round trip" {
    var sample = Sample{
        .id = 99,
        .value = 42.5,
        .name = [_]u8{ 'z', 'd', 'l', 0, 0, 0, 0, 0 },
    };

    var out_len: usize = 0;
    const target_value: c_int = @intCast(@intFromEnum(Target.cpu));
    const bytes_ptr = c_api.serializeForType(Sample, &sample, target_value, &out_len);
    try testing.expect(bytes_ptr != null);
    try testing.expect(out_len > 0);

    const decoded_ptr = c_api.deserializeForType(Sample, bytes_ptr, out_len);
    try testing.expect(decoded_ptr != null);
    try testing.expectEqual(sample.id, decoded_ptr.?.*.id);
    try testing.expectApproxEqAbs(sample.value, decoded_ptr.?.*.value, 0.0001);

    c_api.freeAlloc(@ptrCast(decoded_ptr.?));
    c_api.freeAlloc(@ptrCast(bytes_ptr.?));
}

test "serialize array and count helper return data" {
    var items = [_]Sample{
        .{
            .id = 1,
            .value = 1.0,
            .name = [_]u8{ 'a', 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .id = 2,
            .value = 2.0,
            .name = [_]u8{ 'b', 0, 0, 0, 0, 0, 0, 0 },
        },
    };

    var out_len: usize = 0;
    const bytes_ptr = c_api.serializeArrayForType(Sample, items[0..].ptr, items.len, @intCast(@intFromEnum(Target.cpu)), &out_len);
    try testing.expect(bytes_ptr != null);
    try testing.expect(out_len > 0);

    const count = c_api.arrayCountFromBytes(bytes_ptr, out_len);
    try testing.expectEqual(@as(u64, items.len), count);

    c_api.freeAlloc(@ptrCast(bytes_ptr.?));
}

test "invalid target returns null pointer" {
    var sample = Sample{
        .id = 1,
        .value = 1.0,
        .name = [_]u8{0} ** 8,
    };

    var out_len: usize = 0;
    const invalid_target: c_int = @intCast(@intFromEnum(Target.cuda));
    const bytes_ptr = c_api.serializeForType(Sample, &sample, invalid_target, &out_len);
    try testing.expect(bytes_ptr == null);
}

// ========== Query Handle Tests ==========

test "query handle create and free" {
    const allocator = testing.allocator;
    const samples = [_]Sample{
        .{ .id = 1, .value = 10.0, .name = [_]u8{ 'a', 0, 0, 0, 0, 0, 0, 0 } },
        .{ .id = 2, .value = 20.0, .name = [_]u8{ 'b', 0, 0, 0, 0, 0, 0, 0 } },
    };

    const bytes = try format.serializeArray(Sample, &samples, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    const QH = c_api.QueryHandle(Sample);
    const handle = QH.init(bytes.ptr, bytes.len);
    try testing.expect(handle != null);

    QH.deinit(handle);
}

test "query handle null input sets error" {
    const QH = c_api.QueryHandle(Sample);

    const handle = QH.init(null, 0);
    try testing.expect(handle == null);
    try testing.expectEqual(c_error.Error.null_param, c_error.getError());
}

test "query handle with filters" {
    const allocator = testing.allocator;
    const samples = [_]Sample{
        .{ .id = 1, .value = 10.0, .name = [_]u8{ 'a', 0, 0, 0, 0, 0, 0, 0 } },
        .{ .id = 2, .value = 20.0, .name = [_]u8{ 'b', 0, 0, 0, 0, 0, 0, 0 } },
        .{ .id = 3, .value = 30.0, .name = [_]u8{ 'c', 0, 0, 0, 0, 0, 0, 0 } },
    };

    const bytes = try format.serializeArray(Sample, &samples, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    const QH = c_api.QueryHandle(Sample);
    const handle = QH.init(bytes.ptr, bytes.len);
    try testing.expect(handle != null);
    defer QH.deinit(handle);

    // Filter by id >= 2
    const result = QH.filterU64(handle, "id", @intFromEnum(c_api.Comparison.ge), 2);
    try testing.expectEqual(@as(c_int, 0), result);

    // Set limit
    const limit_result = QH.setLimit(handle, 10);
    try testing.expectEqual(@as(c_int, 0), limit_result);

    // Collect results
    var out_count: usize = 0;
    const results = QH.collect(handle, &out_count);
    try testing.expect(results != null);
    try testing.expectEqual(@as(usize, 2), out_count);

    // Verify results
    try testing.expectEqual(@as(u64, 2), results.?[0].id);
    try testing.expectEqual(@as(u64, 3), results.?[1].id);

    // Free results
    c_api.freeAlloc(@ptrCast(results.?));
}

test "query handle invalid field name returns error" {
    const allocator = testing.allocator;
    const samples = [_]Sample{
        .{ .id = 1, .value = 10.0, .name = [_]u8{ 'a', 0, 0, 0, 0, 0, 0, 0 } },
    };

    const bytes = try format.serializeArray(Sample, &samples, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    const QH = c_api.QueryHandle(Sample);
    const handle = QH.init(bytes.ptr, bytes.len);
    try testing.expect(handle != null);
    defer QH.deinit(handle);

    // Try to filter on non-existent field
    const result = QH.filterU64(handle, "nonexistent", @intFromEnum(c_api.Comparison.eq), 1);
    try testing.expectEqual(@intFromEnum(c_error.Error.invalid_field), result);
}

test "query iterator" {
    const allocator = testing.allocator;
    const samples = [_]Sample{
        .{ .id = 1, .value = 10.0, .name = [_]u8{ 'a', 0, 0, 0, 0, 0, 0, 0 } },
        .{ .id = 2, .value = 20.0, .name = [_]u8{ 'b', 0, 0, 0, 0, 0, 0, 0 } },
        .{ .id = 3, .value = 30.0, .name = [_]u8{ 'c', 0, 0, 0, 0, 0, 0, 0 } },
    };

    const bytes = try format.serializeArray(Sample, &samples, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    const QH = c_api.QueryHandle(Sample);
    const handle = QH.init(bytes.ptr, bytes.len);
    try testing.expect(handle != null);
    defer QH.deinit(handle);

    // Start iterator
    const start_result = QH.iterStart(handle);
    try testing.expectEqual(@as(c_int, 0), start_result);

    // Iterate
    var count: usize = 0;
    while (QH.iterNext(handle)) |item| {
        count += 1;
        try testing.expect(item.id >= 1 and item.id <= 3);
    }
    try testing.expectEqual(@as(usize, 3), count);

    // Reset and iterate again
    QH.iterReset(handle);
    const start_result2 = QH.iterStart(handle);
    try testing.expectEqual(@as(c_int, 0), start_result2);

    count = 0;
    while (QH.iterNext(handle)) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "query count matches collect length" {
    const allocator = testing.allocator;
    const samples = [_]Sample{
        .{ .id = 1, .value = 10.0, .name = [_]u8{ 'a', 0, 0, 0, 0, 0, 0, 0 } },
        .{ .id = 2, .value = 20.0, .name = [_]u8{ 'b', 0, 0, 0, 0, 0, 0, 0 } },
        .{ .id = 3, .value = 30.0, .name = [_]u8{ 'c', 0, 0, 0, 0, 0, 0, 0 } },
    };

    const bytes = try format.serializeArray(Sample, &samples, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    const QH = c_api.QueryHandle(Sample);
    const handle = QH.init(bytes.ptr, bytes.len);
    try testing.expect(handle != null);
    defer QH.deinit(handle);

    // Filter
    _ = QH.filterU64(handle, "id", @intFromEnum(c_api.Comparison.ge), 2);
    _ = QH.setLimit(handle, 10);

    // Count should match collected length
    const count = QH.count(handle);
    try testing.expectEqual(@as(u64, 2), count);

    var out_count: usize = 0;
    const results = QH.collect(handle, &out_count);
    try testing.expectEqual(@as(usize, 2), out_count);

    if (results) |r| {
        c_api.freeAlloc(@ptrCast(r));
    }
}

// ========== Introspection Tests ==========

test "field count matches struct" {
    const field_infos = c_api.generateFieldInfo(Sample);
    try testing.expectEqual(@as(usize, 3), field_infos.len);
}

test "field info has correct data" {
    const field_infos = c_api.generateFieldInfo(Sample);

    // Check 'id' field
    try testing.expectEqualStrings("id", std.mem.sliceTo(field_infos[0].name, 0));
    try testing.expectEqual(c_api.FieldType.u64_type, field_infos[0].field_type);
    try testing.expectEqual(@as(usize, 0), field_infos[0].offset);
    try testing.expectEqual(@as(usize, 8), field_infos[0].size);
    try testing.expectEqual(@as(usize, 0), field_infos[0].array_len);

    // Check 'value' field
    try testing.expectEqualStrings("value", std.mem.sliceTo(field_infos[1].name, 0));
    try testing.expectEqual(c_api.FieldType.f32_type, field_infos[1].field_type);
    try testing.expectEqual(@as(usize, 4), field_infos[1].size);
    try testing.expectEqual(@as(usize, 0), field_infos[1].array_len);

    // Check 'name' field (u8 array)
    try testing.expectEqualStrings("name", std.mem.sliceTo(field_infos[2].name, 0));
    try testing.expectEqual(c_api.FieldType.bytes_type, field_infos[2].field_type);
    try testing.expectEqual(@as(usize, 8), field_infos[2].size);
    try testing.expectEqual(@as(usize, 8), field_infos[2].array_len);
}

// ========== Error Handling Tests ==========

test "error message returns valid string" {
    const msg = c_error.errorMessage(.ok);
    try testing.expectEqualStrings("Success", std.mem.sliceTo(msg, 0));

    const null_msg = c_error.errorMessage(.null_param);
    try testing.expectEqualStrings("Null parameter provided", std.mem.sliceTo(null_msg, 0));
}

test "thread local error state" {
    c_error.setError(.null_param);
    try testing.expectEqual(c_error.Error.null_param, c_error.getError());

    c_error.clearError();
    try testing.expectEqual(c_error.Error.ok, c_error.getError());
}

// ========== Filter Type Tests ==========

test "filter f32 values" {
    const allocator = testing.allocator;
    const samples = [_]Sample{
        .{ .id = 1, .value = 10.0, .name = [_]u8{ 'a', 0, 0, 0, 0, 0, 0, 0 } },
        .{ .id = 2, .value = 20.0, .name = [_]u8{ 'b', 0, 0, 0, 0, 0, 0, 0 } },
        .{ .id = 3, .value = 30.0, .name = [_]u8{ 'c', 0, 0, 0, 0, 0, 0, 0 } },
    };

    const bytes = try format.serializeArray(Sample, &samples, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    const QH = c_api.QueryHandle(Sample);
    const handle = QH.init(bytes.ptr, bytes.len);
    try testing.expect(handle != null);
    defer QH.deinit(handle);

    // Filter by value > 15.0
    const result = QH.filterF32(handle, "value", @intFromEnum(c_api.Comparison.gt), 15.0);
    try testing.expectEqual(@as(c_int, 0), result);

    _ = QH.setLimit(handle, 10);

    var out_count: usize = 0;
    const results = QH.collect(handle, &out_count);
    try testing.expectEqual(@as(usize, 2), out_count);

    if (results) |r| {
        try testing.expectEqual(@as(u64, 2), r[0].id);
        try testing.expectEqual(@as(u64, 3), r[1].id);
        c_api.freeAlloc(@ptrCast(r));
    }
}

test "serialize_into writes into caller buffer and reports BufferTooSmall" {
    var sample = Sample{
        .id = 7,
        .value = 1.5,
        .name = [_]u8{ 'x', 0, 0, 0, 0, 0, 0, 0 },
    };
    const target_value: c_int = @intCast(@intFromEnum(Target.cpu));

    const needed = c_api.serializedSizeForType(Sample, target_value);
    try testing.expect(needed > 0);

    var buf: [4096]u8 = undefined;
    var out_len: usize = 0;
    const code = c_api.serializeIntoForType(Sample, &sample, &buf, buf.len, target_value, &out_len);
    try testing.expectEqual(@intFromEnum(c_error.Error.ok), code);
    try testing.expectEqual(needed, out_len);

    // byte-identical to the allocating path
    var heap_len: usize = 0;
    const heap_ptr = c_api.serializeForType(Sample, &sample, target_value, &heap_len);
    try testing.expect(heap_ptr != null);
    try testing.expectEqual(out_len, heap_len);
    try testing.expectEqualSlices(u8, heap_ptr.?[0..heap_len], buf[0..out_len]);
    c_api.freeAlloc(@ptrCast(heap_ptr.?));

    // undersized buffer
    var small: [4]u8 = undefined;
    const small_code = c_api.serializeIntoForType(Sample, &sample, &small, small.len, target_value, &out_len);
    try testing.expectEqual(@intFromEnum(c_error.Error.buffer_too_small), small_code);
    try testing.expectEqual(c_error.Error.buffer_too_small, c_error.getError());
}

test "mutable handle: full CRUD lifecycle through the C surface" {
    const MH = c_api.MutableHandle(Sample);

    const handle = MH.init(8);
    try testing.expect(handle != null);
    defer MH.deinit(handle);

    // append
    var rec = Sample{ .id = 1, .value = 1.0, .name = [_]u8{0} ** 8 };
    var slot: usize = 0;
    try testing.expectEqual(@intFromEnum(c_error.Error.ok), MH.append(handle, &rec, &slot));
    rec.id = 2;
    try testing.expectEqual(@intFromEnum(c_error.Error.ok), MH.append(handle, &rec, &slot));
    try testing.expectEqual(@as(usize, 1), slot);
    try testing.expectEqual(@as(usize, 2), MH.liveOf(handle));

    // get (zero-copy) and get_verified (copy)
    const p = MH.get(handle, 0);
    try testing.expect(p != null);
    try testing.expectEqual(@as(u64, 1), p.?.id);
    var out: Sample = undefined;
    try testing.expectEqual(@intFromEnum(c_error.Error.ok), MH.getVerified(handle, 1, &out));
    try testing.expectEqual(@as(u64, 2), out.id);

    // update
    rec.id = 22;
    try testing.expectEqual(@intFromEnum(c_error.Error.ok), MH.update(handle, 1, &rec));
    try testing.expectEqual(@intFromEnum(c_error.Error.ok), MH.getVerified(handle, 1, &out));
    try testing.expectEqual(@as(u64, 22), out.id);

    // delete + error codes
    try testing.expectEqual(@intFromEnum(c_error.Error.ok), MH.del(handle, 0));
    try testing.expectEqual(@intFromEnum(c_error.Error.slot_deleted), MH.del(handle, 0));
    try testing.expectEqual(@intFromEnum(c_error.Error.slot_out_of_range), MH.del(handle, 99));
    try testing.expect(MH.get(handle, 0) == null);
    try testing.expectEqual(c_error.Error.slot_deleted, c_error.getError());

    // capacity
    var fill = Sample{ .id = 100, .value = 0, .name = [_]u8{0} ** 8 };
    while (MH.append(handle, &fill, null) == @intFromEnum(c_error.Error.ok)) {}
    try testing.expectEqual(c_error.Error.capacity_full, c_error.getError());
    try testing.expectEqual(@intFromEnum(c_error.Error.ok), MH.reserve(handle, 8));
    try testing.expectEqual(@intFromEnum(c_error.Error.ok), MH.append(handle, &fill, null));

    // compact reclaims the tombstone
    const live_before = MH.liveOf(handle);
    MH.compact(handle);
    try testing.expectEqual(live_before, MH.lenOf(handle));
}

test "mutable handle: iterator reports stale_view after a fence" {
    const MH = c_api.MutableHandle(Sample);

    const handle = MH.init(8);
    try testing.expect(handle != null);
    defer MH.deinit(handle);

    var rec = Sample{ .id = 0, .value = 0, .name = [_]u8{0} ** 8 };
    var i: u64 = 0;
    while (i < 4) : (i += 1) {
        rec.id = i;
        _ = MH.append(handle, &rec, null);
    }

    try testing.expectEqual(@intFromEnum(c_error.Error.ok), MH.iterStart(handle));
    try testing.expect(MH.iterNext(handle) != null);

    // fence mid-iteration
    MH.compact(handle);
    try testing.expect(MH.iterNext(handle) == null);
    try testing.expectEqual(c_error.Error.stale_view, c_error.getError());

    // restart works and runs to honest end-of-iteration
    try testing.expectEqual(@intFromEnum(c_error.Error.ok), MH.iterStart(handle));
    var seen: usize = 0;
    while (MH.iterNext(handle)) |_| seen += 1;
    try testing.expectEqual(@as(usize, 4), seen);
    try testing.expectEqual(c_error.Error.ok, c_error.getError());
}

test "mutable handle: load/flush round-trips wire bytes" {
    const MH = c_api.MutableHandle(Sample);

    var items = [_]Sample{
        .{ .id = 1, .value = 1.0, .name = [_]u8{0} ** 8 },
        .{ .id = 2, .value = 2.0, .name = [_]u8{0} ** 8 },
        .{ .id = 3, .value = 3.0, .name = [_]u8{0} ** 8 },
    };
    var wire_len: usize = 0;
    const wire = c_api.serializeArrayForType(Sample, items[0..].ptr, items.len, @intCast(@intFromEnum(Target.cpu)), &wire_len);
    try testing.expect(wire != null);
    defer c_api.freeAlloc(@ptrCast(wire.?));

    const handle = MH.load(wire, wire_len, 4);
    try testing.expect(handle != null);
    defer MH.deinit(handle);
    try testing.expectEqual(@as(usize, 3), MH.liveOf(handle));

    try testing.expectEqual(@intFromEnum(c_error.Error.ok), MH.del(handle, 1));

    var out_len: usize = 0;
    const flushed = MH.flush(handle, &out_len);
    try testing.expect(flushed != null);
    defer c_api.freeAlloc(@ptrCast(flushed.?));

    try testing.expectEqual(@as(u64, 2), c_api.arrayCountFromBytes(flushed, out_len));
}

test "export names cover 42 functions per schema" {
    const registry = [_]c_api.SchemaDescriptor{
        .{ .Type = Sample, .c_prefix = "sample" },
    };
    const names = comptime c_api.getExportNames(&registry);
    try testing.expectEqual(@as(usize, 42 + 2), names.len);
    try testing.expectEqualStrings("sample_mut_iter_reset", names[names.len - 1]);
    try testing.expectEqualStrings("sample_serialize_into", names[2 + 23]);
}
