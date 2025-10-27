//! Demonstrates schema evolution with migrations

const std = @import("std");
const zdl = @import("zdl");

const UserV1 = struct {
    id: u64,
    name: [32]u8,

    pub const zdl_config = .{ .version = 1 };
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var v1 = UserV1{
        .id = 1,
        .name = [_]u8{0} ** 32,
    };
    std.mem.copyForwards(u8, v1.name[0.."alice".len], "alice");

    const v1_bytes = try zdl.serialize.serialize(v1, .cpu, allocator);
    defer allocator.free(@constCast(v1_bytes));

    const v1_loaded = try zdl.deserialize.deserialize(UserV1, v1_bytes, allocator);
    const v2_migrated = zdl.migrate.migrate(UserV1, UserV2, v1_loaded);

    const name_slice = std.mem.sliceTo(&v2_migrated.name, 0);
    std.debug.print("Migrated to v2: {s}\n", .{name_slice});
}
