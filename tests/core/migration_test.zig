const std = @import("std");
const migrate = @import("zdl").migrate;

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

test "migrate v1 to v2" {
    const v1 = UserV1{
        .id = 1,
        .name = [_]u8{0} ** 32,
    };
    const v2 = migrate.migrate(UserV1, UserV2, v1);
    try std.testing.expectEqual(v1.id, v2.id);
    try std.testing.expectEqualSlices(u8, &v1.name, &v2.name);
    try std.testing.expectEqual(@as(u8, 0), v2.email[0]);
}

test "migrate v2 to v1 (downgrade)" {
    const v2 = UserV2{
        .id = 5,
        .name = [_]u8{0} ** 32,
        .email = "alice@example.com".* ++ [_]u8{0} ** (64 - "alice@example.com".len),
    };
    const v1 = migrate.migrate(UserV2, UserV1, v2);
    try std.testing.expectEqual(v2.id, v1.id);
    try std.testing.expectEqualSlices(u8, &v2.name, &v1.name);
}

test "chained migration v1 -> v2 -> v3" {
    const v1 = UserV1{
        .id = 7,
        .name = [_]u8{0} ** 32,
    };
    const v2 = migrate.migrate(UserV1, UserV2, v1);
    const v3 = migrate.migrate(UserV2, UserV3, v2);
    try std.testing.expectEqual(v1.id, v3.id);
    try std.testing.expectEqualSlices(u8, &v1.name, &v3.name);
}
