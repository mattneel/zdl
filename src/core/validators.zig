const std = @import("std");

pub fn email(value: []const u8) bool {
    if (value.len == 0) return false;

    var has_at = false;
    var has_dot_after_at = false;

    for (value, 0..) |char, idx| {
        if (char == '@') {
            has_at = true;
        } else if (has_at and char == '.') {
            has_dot_after_at = true;
        }

        if (idx >= 254) return false;
    }

    return has_at and has_dot_after_at;
}

pub fn url(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "http://") or
        std.mem.startsWith(u8, value, "https://");
}

pub fn alphanumeric(value: []const u8) bool {
    if (value.len == 0) return false;

    for (value) |char| {
        if (!std.ascii.isAlphanumeric(char)) return false;
    }

    return true;
}
