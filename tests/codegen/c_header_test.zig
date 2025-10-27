const std = @import("std");
const testing = std.testing;
const c_header = @import("zdl").codegen.c_header;

test "generate header for simple schema" {
    const Simple = struct {
        id: u32,
        active: bool,

        pub const zdl_config = .{ .version = 1 };
    };

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(testing.allocator);

    try c_header.generateHeader(Simple, buffer.writer(testing.allocator));

    const text = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "typedef struct Simple"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "uint32_t id;"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "bool active;"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "simple_serialize"));
}

test "generate header emits arrays and nested structs" {
    const Address = struct {
        zip: u32,
        street: [32]u8,

        pub const zdl_config = .{ .version = 1 };
    };

    const User = struct {
        id: u64,
        address: Address,

        pub const zdl_config = .{ .version = 1 };
    };

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(testing.allocator);

    try c_header.generateHeader(User, buffer.writer(testing.allocator));

    const text = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "typedef struct Address"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "typedef struct User"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "uint8_t street[32];"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "Address address;"));
}

test "unsupported types bubble errors" {
    const Bad = struct {
        ptr: *u8,

        pub const zdl_config = .{ .version = 1 };
    };

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(testing.allocator);

    try testing.expectError(c_header.CGenError.UnsupportedType, c_header.generateHeader(Bad, buffer.writer(testing.allocator)));
}
