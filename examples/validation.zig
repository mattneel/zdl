//! Demonstrates changeset validation

const std = @import("std");
const zdl = @import("zdl");

const User = struct {
    id: u64,
    name: [32]u8,
    email: [64]u8,
    score: f32,

    pub const zdl_config = .{
        .version = 1,
        .changeset = struct {
            pub fn validate(
                params: anytype,
                allocator: std.mem.Allocator,
            ) !zdl.changeset.Changeset(User) {
                var cs = zdl.changeset.Changeset(User).init(allocator);
                errdefer cs.deinit();

                try cs.cast(params, &.{ "id", "name", "email", "score" });
                try cs.validateRequired(&.{ "name", "email" });
                try cs.validateLength("name", .{ .min = 3, .max = 32 });
                try cs.validateNumber("score", .{ .min = 0, .max = 1000 });

                return cs;
            }
        },
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const valid_params = .{
        .id = @as(u64, 1),
        .name = "alice",
        .email = "alice@example.com",
        .score = @as(f32, 100.0),
    };

    var cs = try User.zdl_config.changeset.validate(valid_params, allocator);
    defer cs.deinit();

    if (cs.valid()) {
        std.debug.print("Validation passed!\n", .{});
    } else {
        std.debug.print("Validation failed:\n", .{});
        for (cs.errors.items) |err| {
            std.debug.print("  {s}: {s}\n", .{ err.field, err.message });
        }
    }
}
