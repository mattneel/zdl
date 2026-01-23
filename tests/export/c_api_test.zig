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
