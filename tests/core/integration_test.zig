const std = @import("std");
const zdl = @import("zdl");

const migrate = @import("zdl").migrate;
const Target = zdl.Target;

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
