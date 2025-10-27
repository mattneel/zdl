const std = @import("std");
const zdl = @import("zdl");

const format = zdl.format;
const query = zdl.query;
const Target = zdl.Target;
const QueryError = query.QueryError;

const Sample = struct {
    id: u64,
    score: f32,
    flag: i32,

    pub const zdl_config = .{ .version = 1 };
};

fn serializeSamples(allocator: std.mem.Allocator, samples: []const Sample) ![]const u8 {
    return try format.serializeArray(Sample, samples, Target.cpu, allocator);
}

test "query iterator yields zero-copy pointers" {
    const allocator = std.testing.allocator;
    const samples = [_]Sample{
        .{ .id = 1, .score = 10.5, .flag = 1 },
        .{ .id = 2, .score = 20.5, .flag = 1 },
    };

    const bytes = try serializeSamples(allocator, &samples);
    defer allocator.free(@constCast(bytes));

    var qb = query.QueryBuilder(Sample).init(bytes, allocator);
    defer qb.deinit();

    var it = try qb.iter();
    const first = it.next() orelse unreachable;
    const bytes_start = @intFromPtr(bytes.ptr);
    const bytes_end = bytes_start + bytes.len;
    const ptr_addr = @intFromPtr(first);
    try std.testing.expect(ptr_addr >= bytes_start and ptr_addr < bytes_end);
    try std.testing.expectEqual(samples[0].id, first.id);
}

test "query filter operators" {
    const allocator = std.testing.allocator;
    const samples = [_]Sample{
        .{ .id = 1, .score = 5.0, .flag = -1 },
        .{ .id = 2, .score = 7.5, .flag = 0 },
        .{ .id = 3, .score = 7.5, .flag = 1 },
        .{ .id = 4, .score = 9.0, .flag = 2 },
    };

    const bytes = try serializeSamples(allocator, &samples);
    defer allocator.free(@constCast(bytes));

    var qb = query.QueryBuilder(Sample).init(bytes, allocator);
    defer qb.deinit();

    try qb.filter("id", .eq, @as(u64, 3));
    var it = try qb.iter();
    const third = it.next() orelse unreachable;
    try std.testing.expectEqual(@as(u64, 3), third.id);
    try std.testing.expect(it.next() == null);

    qb.clearFilters();
    try qb.filter("score", .ne, 5.0);
    it = try qb.iter();
    try std.testing.expect(it.next().?.id != 1);

    qb.clearFilters();
    try qb.filter("score", .lt, 9.0);
    it = try qb.iter();
    try std.testing.expectEqual(@as(u64, 1), it.next().?.id);
    try std.testing.expectEqual(@as(u64, 2), it.next().?.id);
    try std.testing.expectEqual(@as(u64, 3), it.next().?.id);
    try std.testing.expect(it.next() == null);

    qb.clearFilters();
    try qb.filter("score", .ge, 7.5);
    it = try qb.iter();
    try std.testing.expectEqual(@as(u64, 2), it.next().?.id);
}

test "query combines multiple filters with AND logic" {
    const allocator = std.testing.allocator;
    const samples = [_]Sample{
        .{ .id = 1, .score = 4.0, .flag = 1 },
        .{ .id = 2, .score = 8.0, .flag = 1 },
        .{ .id = 3, .score = 8.0, .flag = 0 },
    };

    const bytes = try serializeSamples(allocator, &samples);
    defer allocator.free(@constCast(bytes));

    var qb = query.QueryBuilder(Sample).init(bytes, allocator);
    defer qb.deinit();

    try qb.filter("score", .eq, 8.0);
    try qb.filter("flag", .eq, 1);

    var it = try qb.iter();
    const match = it.next() orelse unreachable;
    try std.testing.expectEqual(@as(u64, 2), match.id);
    try std.testing.expect(it.next() == null);
}

test "query limit enforcement and collection" {
    const allocator = std.testing.allocator;
    var samples = [_]Sample{
        .{ .id = 1, .score = 1.0, .flag = 0 },
        .{ .id = 2, .score = 2.0, .flag = 0 },
        .{ .id = 3, .score = 3.0, .flag = 0 },
    };

    const bytes = try serializeSamples(allocator, &samples);
    defer allocator.free(@constCast(bytes));

    var qb = query.QueryBuilder(Sample).init(bytes, allocator);
    defer qb.deinit();

    qb.limit(2);
    var it = try qb.iter();
    try std.testing.expectEqual(@as(u64, 1), it.next().?.id);
    try std.testing.expectEqual(@as(u64, 2), it.next().?.id);
    try std.testing.expect(it.next() == null);

    qb.clearFilters();
    qb.limit(3);
    const collected = try qb.collect();
    defer allocator.free(@constCast(collected));
    try std.testing.expectEqual(@as(usize, 3), collected.len);
    try std.testing.expectEqual(@as(u64, 3), collected[2].id);
}

test "query returns empty result set when filters eliminate all rows" {
    const allocator = std.testing.allocator;
    const samples = [_]Sample{
        .{ .id = 1, .score = 2.0, .flag = 0 },
        .{ .id = 2, .score = 4.0, .flag = 1 },
    };

    const bytes = try serializeSamples(allocator, &samples);
    defer allocator.free(@constCast(bytes));

    var qb = query.QueryBuilder(Sample).init(bytes, allocator);
    defer qb.deinit();

    try qb.filter("id", .eq, @as(u64, 99));
    var it = try qb.iter();
    try std.testing.expect(it.next() == null);

    qb.clearFilters();
    qb.limit(1);
    try qb.filter("score", .gt, 100.0);
    const collected = try qb.collect();
    defer allocator.free(@constCast(collected));
    try std.testing.expectEqual(@as(usize, 0), collected.len);
}

test "query enforces max filter depth" {
    const allocator = std.testing.allocator;
    const single = [_]Sample{.{ .id = 1, .score = 1.0, .flag = 0 }};
    const bytes = try serializeSamples(allocator, &single);
    defer allocator.free(@constCast(bytes));

    var qb = query.QueryBuilder(Sample).init(bytes, allocator);
    defer qb.deinit();

    var i: usize = 0;
    while (i < query.MAX_FILTER_DEPTH) : (i += 1) {
        try qb.filter("id", .ge, @as(u64, 0));
    }

    try std.testing.expectError(QueryError.TooManyFilters, qb.filter("id", .ge, @as(u64, 0)));
}

test "query enforces max results bound" {
    const allocator = std.testing.allocator;
    const Item = struct {
        value: u8,
        pub const zdl_config = .{ .version = 1 };
    };

    const count = query.MAX_RESULTS + 1;
    const items = try allocator.alloc(Item, count);
    defer allocator.free(items);
    for (items) |*item| item.* = .{ .value = 0 };

    const bytes = try format.serializeArray(Item, items, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    var qb = query.QueryBuilder(Item).init(bytes, allocator);
    defer qb.deinit();

    try std.testing.expectError(QueryError.TooManyResults, qb.iter());
}
