const std = @import("std");
const zdl = @import("zdl");

const migrate = @import("zdl").migrate;
const Target = zdl.Target;
const Changeset = zdl.changeset.Changeset;

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
