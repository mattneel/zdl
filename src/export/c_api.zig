const std = @import("std");
const zdl = @import("../root.zig");

const Target = zdl.Target;
const allocator = std.heap.c_allocator;

/// Schema descriptor for C API export. Define a registry of these in your
/// schemas module and pass it to `exportCApi`.
pub const SchemaDescriptor = struct {
    /// Type to expose through the C API.
    Type: type,
    /// Lowercase snake prefix used for function names and header files.
    /// Example: "user" produces user_serialize, user_deserialize, etc.
    c_prefix: []const u8,
};

fn toTarget(value: c_int) ?Target {
    const raw = std.math.cast(u8, value) orelse return null;
    const parsed = std.meta.intToEnum(Target, raw) catch return null;
    return switch (parsed) {
        .cuda, .metal => null,
        else => parsed,
    };
}

pub fn serializeForType(comptime T: type, value: ?*const T, target: c_int, out_len: ?*usize) ?[*]u8 {
    const ptr = value orelse return null;
    const out_len_ptr = out_len orelse return null;
    const target_enum = toTarget(target) orelse return null;

    const bytes = zdl.serialize.serialize(ptr.*, target_enum, allocator) catch {
        return null;
    };

    out_len_ptr.* = bytes.len;
    return @constCast(bytes.ptr);
}

pub fn deserializeForType(comptime T: type, bytes: ?[*]const u8, len: usize) ?*T {
    if (len == 0) return null;
    const ptr = bytes orelse return null;
    const slice = ptr[0..len];

    const value = zdl.deserialize.deserialize(T, slice, allocator) catch {
        return null;
    };

    const mem = std.c.malloc(@sizeOf(T)) orelse return null;
    const typed: *T = @ptrCast(@alignCast(mem));
    typed.* = value;
    return typed;
}

pub fn serializeArrayForType(comptime T: type, items: ?[*]const T, count: usize, target: c_int, out_len: ?*usize) ?[*]u8 {
    const out_len_ptr = out_len orelse return null;
    const target_enum = toTarget(target) orelse return null;

    const slice: []const T = if (count == 0) &[_]T{} else blk: {
        const ptr = items orelse return null;
        break :blk ptr[0..count];
    };

    const bytes = zdl.format.serializeArray(T, slice, target_enum, allocator) catch {
        return null;
    };

    out_len_ptr.* = bytes.len;
    return @constCast(bytes.ptr);
}

pub fn arrayCountFromBytes(bytes: ?[*]const u8, len: usize) u64 {
    if (len == 0) return 0;
    const ptr = bytes orelse return 0;
    const slice = ptr[0..len];
    return zdl.format.arrayCount(slice) catch 0;
}

pub fn freeAlloc(ptr: ?*anyopaque) void {
    if (ptr) |p| {
        std.c.free(p);
    }
}

/// Export C API functions for all schemas in the provided registry.
/// Call this from a comptime block in your library root file:
///
/// ```zig
/// const zdl = @import("zdl");
/// const my_schemas = @import("my_schemas.zig");
///
/// comptime {
///     zdl.interop.c_api.exportCApi(&my_schemas.registry);
/// }
/// ```
///
/// This generates the following C functions for each schema:
/// - `{prefix}_serialize` - Serialize a struct to bytes
/// - `{prefix}_deserialize` - Deserialize bytes to a struct
/// - `{prefix}_free` - Free memory allocated by the API
/// - `{prefix}_serialize_array` - Serialize an array of structs
/// - `{prefix}_array_count` - Get count from serialized array bytes
pub fn exportCApi(comptime registry: []const SchemaDescriptor) void {
    for (registry) |entry| {
        const T = entry.Type;
        const prefix = entry.c_prefix;

        const SerializeWrapper = struct {
            fn call(value: ?*const T, target: c_int, out_len: ?*usize) callconv(.c) ?[*]u8 {
                return serializeForType(T, value, target, out_len);
            }
        };
        @export(
            &SerializeWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_serialize", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const DeserializeWrapper = struct {
            fn call(bytes: ?[*]const u8, len: usize) callconv(.c) ?*T {
                return deserializeForType(T, bytes, len);
            }
        };
        @export(
            &DeserializeWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_deserialize", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const FreeWrapper = struct {
            fn call(ptr: ?*anyopaque) callconv(.c) void {
                freeAlloc(ptr);
            }
        };
        @export(
            &FreeWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_free", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const SerializeArrayWrapper = struct {
            fn call(items: ?[*]const T, count: usize, target: c_int, out_len: ?*usize) callconv(.c) ?[*]u8 {
                return serializeArrayForType(T, items, count, target, out_len);
            }
        };
        @export(
            &SerializeArrayWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_serialize_array", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const ArrayCountWrapper = struct {
            fn call(bytes: ?[*]const u8, len: usize) callconv(.c) u64 {
                return arrayCountFromBytes(bytes, len);
            }
        };
        @export(
            &ArrayCountWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_array_count", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );
    }
}

/// Generate the list of exported symbol names for a registry.
/// Use this when configuring export_symbol_names on your library module in build.zig.
pub fn getExportNames(comptime registry: []const SchemaDescriptor) []const []const u8 {
    comptime var names: [registry.len * 5][]const u8 = undefined;
    inline for (registry, 0..) |entry, i| {
        names[i * 5 + 0] = std.fmt.comptimePrint("{s}_serialize", .{entry.c_prefix});
        names[i * 5 + 1] = std.fmt.comptimePrint("{s}_deserialize", .{entry.c_prefix});
        names[i * 5 + 2] = std.fmt.comptimePrint("{s}_free", .{entry.c_prefix});
        names[i * 5 + 3] = std.fmt.comptimePrint("{s}_serialize_array", .{entry.c_prefix});
        names[i * 5 + 4] = std.fmt.comptimePrint("{s}_array_count", .{entry.c_prefix});
    }
    const final = names;
    return &final;
}
