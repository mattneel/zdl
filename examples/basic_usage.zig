//! Demonstrates basic serialization and deserialization

const std = @import("std");
const zdl = @import("zdl");

const User = struct {
    id: u64,
    name: [32]u8,
    email: [64]u8,
    score: f32,

    pub const zdl_config = .{ .version = 1 };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var user = User{
        .id = 1,
        .name = [_]u8{0} ** 32,
        .email = [_]u8{0} ** 64,
        .score = 100.0,
    };
    std.mem.copyForwards(u8, user.name[0.."alice".len], "alice");
    std.mem.copyForwards(u8, user.email[0.."alice@example.com".len], "alice@example.com");

    const bytes = try zdl.serialize.serialize(user, .cpu, allocator);
    defer allocator.free(@constCast(bytes));

    std.debug.print("Serialized {d} bytes\n", .{bytes.len});

    const loaded = try zdl.deserialize.deserialize(User, bytes, allocator);
    const name_slice = std.mem.sliceTo(&loaded.name, 0);
    std.debug.print("User {d}: {s}\n", .{ loaded.id, name_slice });
}
