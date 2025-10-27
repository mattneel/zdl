//! Demonstrates zero-copy querying

const std = @import("std");
const zdl = @import("zdl");

const User = struct {
    id: u64,
    score: f32,

    pub const zdl_config = .{ .version = 1 };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var users: [100]User = undefined;
    for (&users, 0..) |*user, i| {
        user.* = .{
            .id = @intCast(i),
            .score = @floatFromInt(i * 10),
        };
    }

    const bytes = try zdl.format.serializeArray(User, &users, .cpu, allocator);
    defer allocator.free(@constCast(bytes));

    var qb = zdl.query.query(User, bytes, allocator);
    defer qb.deinit();

    _ = try qb.filter("score", .gt, @as(f32, 500.0));
    _ = qb.limit(10);
    const results = try qb.collect();
    defer allocator.free(@constCast(results));

    std.debug.print("Found {d} users with score > 500\n", .{results.len});
}
