const std = @import("std");
const zdl = @import("zdl");

const migrate = @import("zdl").migrate;
const query = @import("zdl").query;
const Target = zdl.Target;
const Changeset = zdl.changeset.Changeset;
const format = zdl.format;

const UserV1 = struct {
    id: u64,
    name: [32]u8,

    pub const zdl_config = .{
        .version = 1,
    };
};

const UserV2 = struct {
    id: u64,
    name: [32]u8,
    email: [64]u8,

    pub const zdl_config = .{
        .version = 2,
        .migrations = .{
            .from_v1 = struct {
                pub fn up(v1: UserV1) UserV2 {
                    return .{
                        .id = v1.id,
                        .name = v1.name,
                        .email = [_]u8{0} ** 64,
                    };
                }

                pub fn down(v2: UserV2) UserV1 {
                    return .{
                        .id = v2.id,
                        .name = v2.name,
                    };
                }
            },
        },
    };
};

const UserV3 = struct {
    id: u64,
    name: [32]u8,
    email: [64]u8,
    score: f32,

    pub const zdl_config = .{
        .version = 3,
        .migrations = .{
            .from_v2 = struct {
                pub fn up(v2: UserV2) UserV3 {
                    return .{
                        .id = v2.id,
                        .name = v2.name,
                        .email = v2.email,
                        .score = 0,
                    };
                }

                pub fn down(v3: UserV3) UserV2 {
                    return .{
                        .id = v3.id,
                        .name = v3.name,
                        .email = v3.email,
                        .score = 0,
                    };
                }
            },
        },
    };
};

fn emptyName() [32]u8 {
    return [_]u8{0} ** 32;
}

test "manual migration from serialized v1 to v3" {
    const allocator = std.testing.allocator;
    const user_v1 = UserV1{ .id = 100, .name = emptyName() };

    const bytes = try zdl.serialize.serialize(user_v1, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    const decoded_v1 = try zdl.deserialize.deserialize(UserV1, bytes, allocator);
    const v2 = migrate.migrate(UserV1, UserV2, decoded_v1);
    const v3 = migrate.migrate(UserV2, UserV3, v2);
    try std.testing.expectEqual(user_v1.id, v3.id);
    try std.testing.expectEqualSlices(u8, &user_v1.name, &v3.name);
}

const ValidatedUser = struct {
    id: u64,
    name: [32]u8,
    email: [64]u8,
    score: f32,

    pub const zdl_config = .{
        .version = 1,
        .changeset = struct {
            pub fn validate(params: anytype, allocator: std.mem.Allocator) !Changeset(ValidatedUser) {
                var cs = Changeset(ValidatedUser).init(allocator);
                errdefer cs.deinit();

                try cs.cast(params, comptime &.{ "id", "name", "email", "score" });
                try cs.validateRequired(comptime &.{ "id", "name", "email" });
                try cs.validateLength("name", .{ .min = 3, .max = 32 });
                try cs.validateNumber("score", .{ .min = 0, .max = 1000 });

                return cs;
            }
        },
    };
};

test "changeset validates before serialization" {
    const allocator = std.testing.allocator;
    const Params = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
        score: f32,
    };

    var cs = try ValidatedUser.zdl_config.changeset.validate(Params{
        .id = @as(u64, 42),
        .name = "valid-user",
        .email = "valid@example.com",
        .score = 88.5,
    }, allocator);
    defer cs.deinit();

    const user = try cs.apply();

    const bytes = try zdl.serialize.serialize(user, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    const decoded = try zdl.deserialize.deserialize(ValidatedUser, bytes, allocator);
    try std.testing.expectEqual(user.id, decoded.id);
    try std.testing.expectEqualSlices(u8, &user.name, &decoded.name);
    try std.testing.expectEqualSlices(u8, &user.email, &decoded.email);
    try std.testing.expectEqual(user.score, decoded.score);
}

test "changeset blocks invalid serialization attempts" {
    const allocator = std.testing.allocator;
    const Params = struct {
        id: u64,
        name: []const u8,
        score: f32,
    };

    var cs = try ValidatedUser.zdl_config.changeset.validate(Params{
        .id = @as(u64, 7),
        .name = "no",
        .score = -5.0,
    }, allocator);
    defer cs.deinit();

    try std.testing.expect(!cs.valid());
    try std.testing.expectError(error.ValidationFailed, cs.apply());
    try std.testing.expectEqual(@as(usize, 3), cs.errors.items.len);
    try std.testing.expect(std.mem.eql(u8, cs.errors.items[0].field, "email"));
}

const QueryUser = struct {
    id: u64,
    score: f32,
    active: u8,

    pub const zdl_config = .{ .version = 1 };
};

test "query integration filters and collects from serialized array" {
    const allocator = std.testing.allocator;
    const users = [_]QueryUser{
        .{ .id = 1, .score = 25.0, .active = 0 },
        .{ .id = 2, .score = 55.0, .active = 1 },
        .{ .id = 3, .score = 72.0, .active = 1 },
        .{ .id = 4, .score = 40.0, .active = 1 },
    };

    const bytes = try format.serializeArray(QueryUser, &users, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    var qb = query.QueryBuilder(QueryUser).init(bytes, allocator);
    defer qb.deinit();

    _ = qb.limit(3);
    _ = try qb.filter("active", .eq, @as(u8, 1));
    _ = try qb.filter("score", .ge, @as(f32, 50.0));

    const results = try qb.collect();
    defer allocator.free(@constCast(results));
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(u64, 2), results[0].id);
    try std.testing.expectEqual(@as(u64, 3), results[1].id);
}

test "query integration exposes zero-copy iteration" {
    const allocator = std.testing.allocator;
    const users = [_]QueryUser{
        .{ .id = 10, .score = 11.0, .active = 1 },
        .{ .id = 11, .score = 12.0, .active = 1 },
    };

    const bytes = try format.serializeArray(QueryUser, &users, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    var qb = query.QueryBuilder(QueryUser).init(bytes, allocator);
    defer qb.deinit();

    var it = try qb.iter();
    const first = it.next() orelse unreachable;
    const addr = @intFromPtr(first);
    const start = @intFromPtr(bytes.ptr);
    const end = start + bytes.len;
    try std.testing.expect(addr >= start and addr < end);
}

test "query iterator throughput exceeds target" {
    const allocator = std.testing.allocator;
    const PerfSample = struct {
        value: u64,
        pub const zdl_config = .{ .version = 1 };
    };

    const count: usize = 512 * 1024;
    const items = try allocator.alloc(PerfSample, count);
    defer allocator.free(items);
    for (items, 0..) |*item, idx| item.* = .{ .value = @intCast(idx) };

    const bytes = try format.serializeArray(PerfSample, items, Target.cpu, allocator);
    defer allocator.free(@constCast(bytes));

    var qb = query.QueryBuilder(PerfSample).init(bytes, allocator);
    defer qb.deinit();

    var it = try qb.iter();
    var processed: usize = 0;
    var timer = try std.time.Timer.start();
    while (it.next()) |entry| {
        const expected_value: u64 = @intCast(processed);
        try std.testing.expectEqual(expected_value, entry.value);
        processed += 1;
    }
    const elapsed = timer.read() + 1; // avoid divide by zero
    const total_bytes = processed * @sizeOf(PerfSample);
    const throughput = (@as(u128, total_bytes) * 1_000_000_000) / @as(u128, elapsed);
    const target_throughput: u128 = 100 * 1024 * 1024;
    try std.testing.expect(throughput >= target_throughput);
}
