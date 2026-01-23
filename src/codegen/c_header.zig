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

    try writer.writeAll("#include \"zdl.h\"\n\n");

    var emitted = std.StringHashMap(bool).init(arena_allocator);
    try emitStructTree(T, writer, &emitted, arena_allocator);
    try writer.writeByte('\n');

    // Opaque query handle type
    try writer.print("// Opaque query handle\n", .{});
    try writer.print("struct {s}_query;\n\n", .{prefix});

    // Serialization functions
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

    // Query functions
    try writer.writeAll("// ========== Query API ==========\n\n");

    try writer.writeAll("// Create a new query handle from serialized array bytes\n");
    try writer.print("struct {s}_query* {s}_query_new(const uint8_t* bytes, size_t len);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Free a query handle\n");
    try writer.print("void {s}_query_free(struct {s}_query* q);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Add a filter on a uint64 field\n");
    try writer.print("zdl_error_t {s}_query_filter_u64(struct {s}_query* q, const char* field, zdl_cmp_t cmp, uint64_t value);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Add a filter on an int64 field\n");
    try writer.print("zdl_error_t {s}_query_filter_i64(struct {s}_query* q, const char* field, zdl_cmp_t cmp, int64_t value);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Add a filter on a float field\n");
    try writer.print("zdl_error_t {s}_query_filter_f32(struct {s}_query* q, const char* field, zdl_cmp_t cmp, float value);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Add a filter on a double field\n");
    try writer.print("zdl_error_t {s}_query_filter_f64(struct {s}_query* q, const char* field, zdl_cmp_t cmp, double value);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Add a filter on a bool field\n");
    try writer.print("zdl_error_t {s}_query_filter_bool(struct {s}_query* q, const char* field, zdl_cmp_t cmp, bool value);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Set the maximum number of results to return\n");
    try writer.print("zdl_error_t {s}_query_limit(struct {s}_query* q, size_t limit);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Set the number of results to skip (offset)\n");
    try writer.print("zdl_error_t {s}_query_offset(struct {s}_query* q, size_t offset);\n\n", .{ prefix, prefix });

    try writer.print("// Collect all matching results into a malloc'd array (caller must free with {s}_free)\n", .{prefix});
    try writer.print("{s}* {s}_query_collect(struct {s}_query* q, size_t* out_count);\n\n", .{ simple_name, prefix, prefix });

    try writer.writeAll("// Count matching results without materializing them\n");
    try writer.print("uint64_t {s}_query_count(struct {s}_query* q);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Initialize the iterator (must be called before iter_next)\n");
    try writer.print("zdl_error_t {s}_query_iter_start(struct {s}_query* q);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Get the next matching item (returns NULL when done)\n");
    try writer.writeAll("// NOTE: Returned pointer is valid only until the next iter_next call\n");
    try writer.writeAll("// NOTE: Returned pointer is valid only while the query handle is alive\n");
    try writer.print("const {s}* {s}_query_iter_next(struct {s}_query* q);\n\n", .{ simple_name, prefix, prefix });

    try writer.writeAll("// Reset the iterator to the beginning\n");
    try writer.print("void {s}_query_iter_reset(struct {s}_query* q);\n\n", .{ prefix, prefix });

    // Introspection functions
    try writer.writeAll("// ========== Introspection API ==========\n\n");

    try writer.writeAll("// Get the number of fields in the struct\n");
    try writer.print("size_t {s}_field_count(void);\n\n", .{prefix});

    try writer.writeAll("// Get field info by index (returns NULL if index out of bounds)\n");
    try writer.print("const zdl_field_info_t* {s}_field_info(size_t index);\n\n", .{prefix});

    try writer.writeAll("// Get field info by name (returns NULL if not found)\n");
    try writer.print("const zdl_field_info_t* {s}_field_by_name(const char* name);\n\n", .{prefix});

    try writer.writeAll("// Get the size of the struct in bytes\n");
    try writer.print("size_t {s}_struct_size(void);\n\n", .{prefix});

    try writer.print("#endif // {s}_H\n", .{guard});
}

fn emitStructDefinition(
    comptime T: type,
    comptime name: []const u8,
    writer: anytype,
    alloc: std.mem.Allocator,
) !void {
    try writer.print("typedef struct {s} {{\n", .{name});

    const fields = std.meta.fields(T);
    inline for (fields) |field| {
        if (field.is_comptime) continue;

        try emitField(field.type, field.name, 1, writer, alloc);
    }

    try writer.print("}} {s};\n", .{name});
}

fn emitField(
    comptime FieldType: type,
    comptime field_name: []const u8,
    indent_level: usize,
    writer: anytype,
    alloc: std.mem.Allocator,
) !void {
    switch (@typeInfo(FieldType)) {
        .bool, .int, .float, .array => {
            const fragments = try toCType(FieldType, alloc);
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

fn toCType(comptime T: type, alloc: std.mem.Allocator) CGenError!CTypeFragments {
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
            const child = try toCType(info.child, alloc);
            const suffix = try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ child.suffix, info.len });
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

fn upperSnake(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    const buf = try alloc.alloc(u8, name.len * 2);
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

fn lowerSnake(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    const buf = try alloc.alloc(u8, name.len * 2);
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
    alloc: std.mem.Allocator,
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
        try processType(field.type, writer, emitted, alloc);
    }

    const simple = comptime simplifyTypeName(full_name);
    try emitStructDefinition(T, simple, writer, alloc);
    try writer.writeByte('\n');
    entry.value_ptr.* = true;
}

fn processType(
    comptime T: type,
    writer: anytype,
    emitted: *std.StringHashMap(bool),
    alloc: std.mem.Allocator,
) !void {
    switch (@typeInfo(T)) {
        .@"struct" => try emitStructTree(T, writer, emitted, alloc),
        .array => |info| try processType(info.child, writer, emitted, alloc),
        else => {},
    }
}
