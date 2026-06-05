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

    // Opaque handle types
    try writer.print("// Opaque query handle\n", .{});
    try writer.print("struct {s}_query;\n\n", .{prefix});
    try writer.print("// Opaque mutable container handle\n", .{});
    try writer.print("struct {s}_mut;\n\n", .{prefix});

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

    try writer.writeAll("// Serialize into a caller-provided buffer (zero allocation)\n");
    try writer.print(
        "zdl_error_t {s}_serialize_into(const {s}* value, uint8_t* dest, size_t dest_len, zdl_target_t target, size_t* out_len);\n\n",
        .{ prefix, simple_name },
    );

    try writer.writeAll("// Number of bytes serialize/serialize_into produce for this schema\n");
    try writer.print("size_t {s}_serialized_size(zdl_target_t target);\n\n", .{prefix});

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

    // Mutable container functions
    try writer.writeAll("// ========== Mutable Container API ==========\n");
    try writer.writeAll("// In-memory CRUD over the array container format. Integrity moves to a\n");
    try writer.writeAll("// per-record CRC; deletes are tombstones; records relocate ONLY at the\n");
    try writer.writeAll("// fences (compact, reserve). Pointers returned by mut_get/mut_iter_next\n");
    try writer.writeAll("// are invalidated by a fence; watch mut_generation to detect fences.\n\n");

    try writer.writeAll("// Create an empty mutable container with the given slot capacity\n");
    try writer.print("struct {s}_mut* {s}_mut_new(size_t capacity);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Load a serialized array container (validates header and container CRC)\n");
    try writer.print("struct {s}_mut* {s}_mut_load(const uint8_t* bytes, size_t len, size_t extra_capacity);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Free a mutable container handle\n");
    try writer.print("void {s}_mut_free(struct {s}_mut* m);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Append a record; fails with ZDL_ERR_CAPACITY_FULL instead of relocating\n");
    try writer.print("zdl_error_t {s}_mut_append(struct {s}_mut* m, const {s}* value, size_t* out_slot);\n\n", .{ prefix, prefix, simple_name });

    try writer.writeAll("// Zero-copy read (pointer valid until compact/reserve)\n");
    try writer.print("const {s}* {s}_mut_get(struct {s}_mut* m, size_t slot);\n\n", .{ simple_name, prefix, prefix });

    try writer.writeAll("// Integrity-checked point read: verifies the record CRC, copies into out\n");
    try writer.print("zdl_error_t {s}_mut_get_verified(struct {s}_mut* m, size_t slot, {s}* out);\n\n", .{ prefix, prefix, simple_name });

    try writer.writeAll("// In-place update; re-CRCs exactly one record\n");
    try writer.print("zdl_error_t {s}_mut_update(struct {s}_mut* m, size_t slot, const {s}* value);\n\n", .{ prefix, prefix, simple_name });

    try writer.writeAll("// Tombstone delete: no bytes move, existing pointers stay readable\n");
    try writer.print("zdl_error_t {s}_mut_delete(struct {s}_mut* m, size_t slot);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Relocation fence: reclaim tombstones (order preserved), bump generation\n");
    try writer.print("void {s}_mut_compact(struct {s}_mut* m);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Relocation fence: grow capacity; failure-atomic on OOM\n");
    try writer.print("zdl_error_t {s}_mut_reserve(struct {s}_mut* m, size_t additional);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Slots in use, including tombstoned ones\n");
    try writer.print("size_t {s}_mut_len(const struct {s}_mut* m);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Live (non-deleted) record count\n");
    try writer.print("size_t {s}_mut_live(const struct {s}_mut* m);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Generation counter; changes exactly when a fence relocates storage\n");
    try writer.print("uint64_t {s}_mut_generation(const struct {s}_mut* m);\n\n", .{ prefix, prefix });

    try writer.print("// Emit a serialized array container of live records (caller must free with {s}_free)\n", .{prefix});
    try writer.print("uint8_t* {s}_mut_flush(struct {s}_mut* m, size_t* out_len);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Start iterating live records in slot order\n");
    try writer.print("zdl_error_t {s}_mut_iter_start(struct {s}_mut* m);\n\n", .{ prefix, prefix });

    try writer.writeAll("// Next live record; NULL at end (zdl_last_error() == ZDL_OK) or after a\n");
    try writer.writeAll("// fence (zdl_last_error() == ZDL_ERR_STALE_VIEW)\n");
    try writer.print("const {s}* {s}_mut_iter_next(struct {s}_mut* m);\n\n", .{ simple_name, prefix, prefix });

    try writer.writeAll("// Reset the mutable container iterator\n");
    try writer.print("void {s}_mut_iter_reset(struct {s}_mut* m);\n\n", .{ prefix, prefix });

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
