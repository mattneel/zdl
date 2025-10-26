const std = @import("std");
const zdl = @import("zdl");

const Changeset = zdl.changeset.Changeset;
const MAX_FIELDS = zdl.changeset.MAX_FIELDS;
const MAX_ERRORS = zdl.changeset.MAX_ERRORS;

const User = struct {
    id: u64,
    name: [32]u8,
    email: [64]u8,
    score: f32,
};

fn repeatName(comptime name: []const u8, comptime count: usize) [count][]const u8 {
    var arr: [count][]const u8 = undefined;
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        arr[idx] = name;
    }
    return arr;
}

test "changeset apply builds struct on valid input" {
    const allocator = std.testing.allocator;
    var cs = Changeset(User).init(allocator);
    defer cs.deinit();

    const Params = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
        score: f32,
    };

    const params = Params{
        .id = @as(u64, 101),
        .name = "Ada",
        .email = "ada@example.com",
        .score = 75.5,
    };

    try cs.cast(params, comptime &.{ "id", "name", "email", "score" });
    try cs.validateRequired(comptime &.{ "id", "name", "email" });
    try cs.validateLength("name", .{ .min = 3, .max = 32 });
    try cs.validateNumber("score", .{ .min = 0, .max = 1000 });

    try std.testing.expect(cs.valid());
    const user = try cs.apply();

    try std.testing.expectEqual(params.id, user.id);
    try std.testing.expect(std.mem.startsWith(u8, user.name[0..params.name.len], params.name));
    try std.testing.expect(std.mem.startsWith(u8, user.email[0..params.email.len], params.email));
    try std.testing.expectEqual(params.score, user.score);
}

test "changeset refuses apply when validation fails" {
    const allocator = std.testing.allocator;
    var cs = Changeset(User).init(allocator);
    defer cs.deinit();

    const Params = struct {
        id: u64,
        name: []const u8,
        score: f32,
    };

    const params = Params{
        .id = @as(u64, 202),
        .name = "Ed",
        .score = -10.0,
    };

    try cs.cast(params, comptime &.{ "id", "name", "score" });
    try cs.validateRequired(comptime &.{"email"});
    try cs.validateLength("name", .{ .min = 3 });
    try cs.validateNumber("score", .{ .min = 0 });

    try std.testing.expect(!cs.valid());
    try std.testing.expectError(error.ValidationFailed, cs.apply());
    try std.testing.expectEqual(@as(usize, 3), cs.errors.items.len);
}

test "changeset enforces field bound" {
    const allocator = std.testing.allocator;
    var cs = Changeset(User).init(allocator);
    defer cs.deinit();

    const params = .{
        .id = @as(u64, 1),
        .name = "ok",
        .email = "ok@example.com",
        .score = 1.0,
    };

    const over_limit = comptime repeatName("id", MAX_FIELDS + 1);

    try std.testing.expectError(error.TooManyFields, cs.cast(params, over_limit[0..]));
}

test "changeset caps collected errors" {
    const allocator = std.testing.allocator;
    var cs = Changeset(User).init(allocator);
    defer cs.deinit();

    const required = comptime repeatName("missing", MAX_ERRORS);

    try cs.validateRequired(required[0..]);
    try std.testing.expectEqual(@as(usize, MAX_ERRORS), cs.errors.items.len);
    try std.testing.expectError(error.TooManyErrors, cs.validateRequired(&.{"overflow_field"}));
}
