const std = @import("std");
const validators = @import("zdl").validators;

test "email validator handles valid and invalid addresses" {
    try std.testing.expect(validators.email("alice@example.com"));
    try std.testing.expect(validators.email("a@b.co"));
    try std.testing.expect(!validators.email("invalid"));
    try std.testing.expect(!validators.email("missing-at.example.com"));

    var long: [255]u8 = undefined;
    @memset(&long, 'a');
    long[0] = 'a';
    long[1] = '@';
    long[2] = 'b';
    long[3] = '.';
    const too_long = long[0..];
    try std.testing.expect(!validators.email(too_long));
}

test "url validator matches http and https prefixes" {
    try std.testing.expect(validators.url("http://example.com"));
    try std.testing.expect(validators.url("https://example.com/path"));
    try std.testing.expect(!validators.url("ftp://example.com"));
    try std.testing.expect(!validators.url("example.com"));
}

test "alphanumeric validator rejects symbols" {
    try std.testing.expect(validators.alphanumeric("abc123"));
    try std.testing.expect(validators.alphanumeric("ZDL2024"));
    try std.testing.expect(!validators.alphanumeric("bad value"));
    try std.testing.expect(!validators.alphanumeric(""));
}
