const std = @import("std");

pub const CGenError = error{
    UnsupportedType,
} || std.mem.Allocator.Error;

/// Generate a C header for the provided Zig struct type.
/// The writer receives a complete translation unit with header guards,
/// struct definition, and public function declarations.
pub fn generateHeader(comptime T: type, writer: anytype) !void {
    const type_name = @typeName(T);
    const simple_name = comptime simplifyTypeName(type_name);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const guard = try upperSnake(arena_allocator, simple_name);
    const prefix = try lowerSnake(arena_allocator, simple_name);

    try writer.print("#ifndef {s}_H\n", .{guard});
    try writer.print("#define {s}_H\n\n", .{guard});

    try writer.writeAll("#include <stdint.h>\n");
    try writer.writeAll("#include <stddef.h>\n");
    try writer.writeAll("#include <stdbool.h>\n\n");

    try writer.writeAll("typedef enum {\n");
    try writer.writeAll("    ZDL_TARGET_CPU = 0,\n");
    try writer.writeAll("    ZDL_TARGET_DISK = 1,\n");
    try writer.writeAll("    ZDL_TARGET_NETWORK = 2,\n");
    try writer.writeAll("} zdl_target_t;\n\n");

    var emitted = std.StringHashMap(bool).init(arena_allocator);
    try emitStructTree(T, writer, &emitted, arena_allocator);
    try writer.writeByte('\n');

    try writer.print("// Serialize to bytes (caller must free with {s}_free)\n", .{prefix});
    try writer.print(
        "uint8_t* {s}_serialize(const {s}* value, zdl_target_t target, size_t* out_len);\n\n",
        .{ prefix, simple_name },
    );

    try writer.print("// Deserialize from bytes (caller must free with {s}_free)\n", .{prefix});
    try writer.print("{s}* {s}_deserialize(const uint8_t* bytes, size_t len);\n\n", .{
        simple_name,
        prefix,
    });

    try writer.writeAll("// Free memory allocated by the zdl C API\n");
    try writer.print("void {s}_free(void* ptr);\n\n", .{prefix});

    try writer.print("// Serialize an array of values (caller must free with {s}_free)\n", .{prefix});
    try writer.print(
        "uint8_t* {s}_serialize_array(const {s}* items, size_t count, zdl_target_t target, size_t* out_len);\n\n",
        .{ prefix, simple_name },
    );

    try writer.writeAll("// Read the array element count from serialized bytes\n");
    try writer.print("uint64_t {s}_array_count(const uint8_t* bytes, size_t len);\n\n", .{prefix});

    try writer.print("#endif // {s}_H\n", .{guard});
}

fn emitStructDefinition(
    comptime T: type,
    comptime name: []const u8,
    writer: anytype,
    allocator: std.mem.Allocator,
) !void {
    try writer.print("typedef struct {s} {{\n", .{name});

    const fields = std.meta.fields(T);
    inline for (fields) |field| {
        if (field.is_comptime) continue;

        try emitField(field.type, field.name, 1, writer, allocator);
    }

    try writer.print("}} {s};\n", .{name});
}

fn emitField(
    comptime FieldType: type,
    comptime field_name: []const u8,
    indent_level: usize,
    writer: anytype,
    allocator: std.mem.Allocator,
) !void {
    switch (@typeInfo(FieldType)) {
        .bool, .int, .float, .array => {
            const fragments = try toCType(FieldType, allocator);
            try writeIndent(writer, indent_level);
            try writer.print("{s} {s}{s};\n", .{ fragments.prefix, field_name, fragments.suffix });
        },
        .@"struct" => {
            const nested_name = simplifyTypeName(@typeName(FieldType));
            try writeIndent(writer, indent_level);
            try writer.print("{s} {s};\n", .{ nested_name, field_name });
        },
        else => return CGenError.UnsupportedType,
    }
}

fn writeIndent(writer: anytype, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.writeAll("    ");
    }
}

const CTypeFragments = struct {
    prefix: []const u8,
    suffix: []const u8,
};

fn toCType(comptime T: type, allocator: std.mem.Allocator) CGenError!CTypeFragments {
    return switch (@typeInfo(T)) {
        .bool => .{ .prefix = "bool", .suffix = "" },
        .int => |info| switch (info.bits) {
            8 => if (info.signedness == .unsigned)
                CTypeFragments{ .prefix = "uint8_t", .suffix = "" }
            else
                CTypeFragments{ .prefix = "int8_t", .suffix = "" },
            16 => if (info.signedness == .unsigned)
                CTypeFragments{ .prefix = "uint16_t", .suffix = "" }
            else
                CTypeFragments{ .prefix = "int16_t", .suffix = "" },
            32 => if (info.signedness == .unsigned)
                CTypeFragments{ .prefix = "uint32_t", .suffix = "" }
            else
                CTypeFragments{ .prefix = "int32_t", .suffix = "" },
            64 => if (info.signedness == .unsigned)
                CTypeFragments{ .prefix = "uint64_t", .suffix = "" }
            else
                CTypeFragments{ .prefix = "int64_t", .suffix = "" },
            else => CGenError.UnsupportedType,
        },
        .float => |info| switch (info.bits) {
            32 => CTypeFragments{ .prefix = "float", .suffix = "" },
            64 => CTypeFragments{ .prefix = "double", .suffix = "" },
            else => CGenError.UnsupportedType,
        },
        .array => |info| blk: {
            const child = try toCType(info.child, allocator);
            const suffix = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ child.suffix, info.len });
            break :blk CTypeFragments{ .prefix = child.prefix, .suffix = suffix };
        },
        .@"struct" => CTypeFragments{ .prefix = simplifyTypeName(@typeName(T)), .suffix = "" },
        else => CGenError.UnsupportedType,
    };
}

pub fn simplifyTypeName(comptime full_name: []const u8) []const u8 {
    comptime var start: usize = 0;
    inline for (full_name, 0..) |ch, idx| {
        if (ch == '.') start = idx + 1;
    }
    return full_name[start..];
}

fn upperSnake(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const buf = try allocator.alloc(u8, name.len * 2);
    var len: usize = 0;

    for (name, 0..) |c, idx| {
        if (std.ascii.isUpper(c) and idx != 0) {
            buf[len] = '_';
            len += 1;
        }
        buf[len] = std.ascii.toUpper(c);
        len += 1;
    }

    return buf[0..len];
}

fn lowerSnake(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const buf = try allocator.alloc(u8, name.len * 2);
    var len: usize = 0;

    for (name, 0..) |c, idx| {
        if (std.ascii.isUpper(c) and idx != 0) {
            buf[len] = '_';
            len += 1;
        }
        buf[len] = std.ascii.toLower(c);
        len += 1;
    }

    return buf[0..len];
}
fn emitStructTree(
    comptime T: type,
    writer: anytype,
    emitted: *std.StringHashMap(bool),
    allocator: std.mem.Allocator,
) !void {
    const full_name = @typeName(T);
    const entry = try emitted.getOrPut(full_name);
    if (entry.found_existing) {
        if (entry.value_ptr.*) return;
    } else {
        entry.key_ptr.* = try emitted.allocator.dupe(u8, full_name);
        entry.value_ptr.* = false;
    }

    inline for (std.meta.fields(T)) |field| {
        if (field.is_comptime) continue;
        try processType(field.type, writer, emitted, allocator);
    }

    const simple = comptime simplifyTypeName(full_name);
    try emitStructDefinition(T, simple, writer, allocator);
    try writer.writeByte('\n');
    entry.value_ptr.* = true;
}

fn processType(
    comptime T: type,
    writer: anytype,
    emitted: *std.StringHashMap(bool),
    allocator: std.mem.Allocator,
) !void {
    switch (@typeInfo(T)) {
        .@"struct" => try emitStructTree(T, writer, emitted, allocator),
        .array => |info| try processType(info.child, writer, emitted, allocator),
        else => {},
    }
}
