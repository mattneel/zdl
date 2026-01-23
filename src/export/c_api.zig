const std = @import("std");
const zdl = @import("../root.zig");
const c_error = @import("c_error.zig");

const Target = zdl.Target;
const query_mod = zdl.query;
const allocator = std.heap.c_allocator;

pub const Error = c_error.Error;
pub const setError = c_error.setError;
pub const getError = c_error.getError;
pub const clearError = c_error.clearError;

/// Schema descriptor for C API export. Define a registry of these in your
/// schemas module and pass it to `exportCApi`.
pub const SchemaDescriptor = struct {
    /// Type to expose through the C API.
    Type: type,
    /// Lowercase snake prefix used for function names and header files.
    /// Example: "user" produces user_serialize, user_deserialize, etc.
    c_prefix: []const u8,
};

/// Comparison operators for query filters (maps to zdl_cmp_t in C).
pub const Comparison = enum(c_int) {
    eq = 0,
    ne = 1,
    lt = 2,
    le = 3,
    gt = 4,
    ge = 5,
};

/// Field type enum for introspection (maps to zdl_field_type_t in C).
pub const FieldType = enum(c_int) {
    bool_type = 0,
    i8_type = 1,
    i16_type = 2,
    i32_type = 3,
    i64_type = 4,
    u8_type = 5,
    u16_type = 6,
    u32_type = 7,
    u64_type = 8,
    f32_type = 9,
    f64_type = 10,
    bytes_type = 11,
    struct_type = 12,
};

/// Field info struct for introspection (maps to zdl_field_info_t in C).
pub const FieldInfo = extern struct {
    name: [*:0]const u8,
    field_type: FieldType,
    offset: usize,
    size: usize,
    array_len: usize, // 0 if not array
};

fn toTarget(value: c_int) ?Target {
    const raw = std.math.cast(u8, value) orelse return null;
    const parsed = std.meta.intToEnum(Target, raw) catch return null;
    return switch (parsed) {
        .cuda, .metal => null,
        else => parsed,
    };
}

fn toOperator(cmp: c_int) ?query_mod.Operator {
    const parsed = std.meta.intToEnum(Comparison, cmp) catch return null;
    return switch (parsed) {
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
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

/// Query handle wrapper for C API. Manages QueryBuilder state and iterator.
pub fn QueryHandle(comptime T: type) type {
    const QB = query_mod.QueryBuilder(T);

    return struct {
        const Self = @This();

        builder: QB,
        iterator: ?QB.Iterator = null,

        pub fn init(bytes: ?[*]const u8, len: usize) ?*Self {
            c_error.clearError();

            if (len == 0) {
                c_error.setError(.null_param);
                return null;
            }
            const ptr = bytes orelse {
                c_error.setError(.null_param);
                return null;
            };
            const slice = ptr[0..len];

            const mem = std.c.malloc(@sizeOf(Self)) orelse {
                c_error.setError(.out_of_memory);
                return null;
            };
            const handle: *Self = @ptrCast(@alignCast(mem));
            handle.* = .{
                .builder = QB.init(slice, allocator),
                .iterator = null,
            };
            return handle;
        }

        pub fn deinit(self: ?*Self) void {
            const handle = self orelse return;
            handle.builder.deinit();
            std.c.free(@ptrCast(handle));
        }

        pub fn filterU64(self: ?*Self, field: ?[*:0]const u8, cmp: c_int, value: u64) c_int {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const field_name = field orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const op = toOperator(cmp) orelse {
                c_error.setError(.type_mismatch);
                return @intFromEnum(Error.type_mismatch);
            };

            const len = std.mem.len(field_name);
            _ = handle.builder.filter(field_name[0..len], op, value) catch |err| {
                const code = c_error.fromQueryError(err);
                c_error.setError(code);
                return @intFromEnum(code);
            };
            return @intFromEnum(Error.ok);
        }

        pub fn filterI64(self: ?*Self, field: ?[*:0]const u8, cmp: c_int, value: i64) c_int {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const field_name = field orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const op = toOperator(cmp) orelse {
                c_error.setError(.type_mismatch);
                return @intFromEnum(Error.type_mismatch);
            };

            const len = std.mem.len(field_name);
            _ = handle.builder.filter(field_name[0..len], op, value) catch |err| {
                const code = c_error.fromQueryError(err);
                c_error.setError(code);
                return @intFromEnum(code);
            };
            return @intFromEnum(Error.ok);
        }

        pub fn filterF32(self: ?*Self, field: ?[*:0]const u8, cmp: c_int, value: f32) c_int {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const field_name = field orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const op = toOperator(cmp) orelse {
                c_error.setError(.type_mismatch);
                return @intFromEnum(Error.type_mismatch);
            };

            const len = std.mem.len(field_name);
            _ = handle.builder.filter(field_name[0..len], op, value) catch |err| {
                const code = c_error.fromQueryError(err);
                c_error.setError(code);
                return @intFromEnum(code);
            };
            return @intFromEnum(Error.ok);
        }

        pub fn filterF64(self: ?*Self, field: ?[*:0]const u8, cmp: c_int, value: f64) c_int {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const field_name = field orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const op = toOperator(cmp) orelse {
                c_error.setError(.type_mismatch);
                return @intFromEnum(Error.type_mismatch);
            };

            const len = std.mem.len(field_name);
            _ = handle.builder.filter(field_name[0..len], op, value) catch |err| {
                const code = c_error.fromQueryError(err);
                c_error.setError(code);
                return @intFromEnum(code);
            };
            return @intFromEnum(Error.ok);
        }

        pub fn filterBool(self: ?*Self, field: ?[*:0]const u8, cmp: c_int, value: bool) c_int {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const field_name = field orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const op = toOperator(cmp) orelse {
                c_error.setError(.type_mismatch);
                return @intFromEnum(Error.type_mismatch);
            };

            // Convert bool to u64 for comparison (bool fields are typically 0/1)
            const int_value: u64 = if (value) 1 else 0;
            const len = std.mem.len(field_name);
            _ = handle.builder.filter(field_name[0..len], op, int_value) catch |err| {
                const code = c_error.fromQueryError(err);
                c_error.setError(code);
                return @intFromEnum(code);
            };
            return @intFromEnum(Error.ok);
        }

        pub fn setLimit(self: ?*Self, limit_val: usize) c_int {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };

            const capped = std.math.cast(u32, limit_val) orelse query_mod.MAX_RESULTS;
            _ = handle.builder.limit(capped);
            return @intFromEnum(Error.ok);
        }

        pub fn setOffset(self: ?*Self, offset_val: usize) c_int {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };

            // Note: QueryBuilder doesn't have native offset support, so we'll need to
            // implement this by skipping items during iteration. For now, store it
            // and handle during collect/iterate.
            _ = handle;
            _ = offset_val;
            // Offset is not natively supported in QueryBuilder yet.
            // This would require extending the query module.
            return @intFromEnum(Error.ok);
        }

        pub fn collect(self: ?*Self, out_count: ?*usize) ?[*]T {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return null;
            };
            const count_ptr = out_count orelse {
                c_error.setError(.null_param);
                return null;
            };

            const results = handle.builder.collect() catch |err| {
                const code = c_error.fromQueryError(err);
                c_error.setError(code);
                return null;
            };

            count_ptr.* = results.len;

            if (results.len == 0) {
                allocator.free(results);
                return null;
            }

            // Transfer ownership to C - the slice is already malloc'd via c_allocator
            // Cast away const since C caller will own the memory
            return @constCast(results.ptr);
        }

        pub fn count(self: ?*Self) u64 {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return 0;
            };

            // Count by iterating without collecting
            var iter = handle.builder.iter() catch |err| {
                const code = c_error.fromQueryError(err);
                c_error.setError(code);
                return 0;
            };

            var n: u64 = 0;
            while (iter.next()) |_| {
                n += 1;
            }
            return n;
        }

        pub fn iterStart(self: ?*Self) c_int {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };

            handle.iterator = handle.builder.iter() catch |err| {
                const code = c_error.fromQueryError(err);
                c_error.setError(code);
                return @intFromEnum(code);
            };
            return @intFromEnum(Error.ok);
        }

        pub fn iterNext(self: ?*Self) ?*const T {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return null;
            };

            var iter = &(handle.iterator orelse {
                c_error.setError(.iterator_not_started);
                return null;
            });

            return iter.next();
        }

        pub fn iterReset(self: ?*Self) void {
            c_error.clearError();

            const handle = self orelse {
                c_error.setError(.null_param);
                return;
            };

            handle.iterator = null;
        }
    };
}

/// Generate field info at comptime for a schema type.
pub fn generateFieldInfo(comptime T: type) []const FieldInfo {
    const fields = std.meta.fields(T);
    comptime var infos: [fields.len]FieldInfo = undefined;

    inline for (fields, 0..) |field, i| {
        if (field.is_comptime) {
            // Skip comptime fields
            infos[i] = .{
                .name = "",
                .field_type = .struct_type,
                .offset = 0,
                .size = 0,
                .array_len = 0,
            };
            continue;
        }

        const ft = comptime fieldTypeFromZig(field.type);
        const arr_len = comptime if (@typeInfo(field.type) == .array)
            @typeInfo(field.type).array.len
        else
            0;

        infos[i] = .{
            .name = field.name ++ "\x00",
            .field_type = ft,
            .offset = @offsetOf(T, field.name),
            .size = @sizeOf(field.type),
            .array_len = arr_len,
        };
    }

    const result = infos;
    return &result;
}

fn fieldTypeFromZig(comptime T: type) FieldType {
    return switch (@typeInfo(T)) {
        .bool => .bool_type,
        .int => |info| switch (info.bits) {
            8 => if (info.signedness == .unsigned) .u8_type else .i8_type,
            16 => if (info.signedness == .unsigned) .u16_type else .i16_type,
            32 => if (info.signedness == .unsigned) .u32_type else .i32_type,
            64 => if (info.signedness == .unsigned) .u64_type else .i64_type,
            else => .struct_type, // fallback
        },
        .float => |info| switch (info.bits) {
            32 => .f32_type,
            64 => .f64_type,
            else => .struct_type,
        },
        .array => |info| blk: {
            // For u8 arrays, treat as bytes
            if (info.child == u8) break :blk .bytes_type;
            break :blk fieldTypeFromZig(info.child);
        },
        .@"struct" => .struct_type,
        else => .struct_type,
    };
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
/// - `{prefix}_query_new` - Create a new query handle
/// - `{prefix}_query_free` - Free a query handle
/// - `{prefix}_query_filter_*` - Add typed filters
/// - `{prefix}_query_limit` - Set result limit
/// - `{prefix}_query_offset` - Set result offset
/// - `{prefix}_query_collect` - Collect results as array
/// - `{prefix}_query_count` - Count matching results
/// - `{prefix}_query_iter_*` - Iterator functions
/// - `{prefix}_field_count` - Get number of fields
/// - `{prefix}_field_info` - Get field info by index
/// - `{prefix}_field_by_name` - Get field info by name
/// - `{prefix}_struct_size` - Get struct size
pub fn exportCApi(comptime registry: []const SchemaDescriptor) void {
    // Export global error functions
    @export(&c_error.zdl_last_error, .{
        .name = "zdl_last_error",
        .linkage = .strong,
        .visibility = .default,
    });
    @export(&c_error.zdl_error_message, .{
        .name = "zdl_error_message",
        .linkage = .strong,
        .visibility = .default,
    });

    for (registry) |entry| {
        const T = entry.Type;
        const prefix = entry.c_prefix;
        const QH = QueryHandle(T);

        // Serialize
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

        // Deserialize
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

        // Free
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

        // Serialize array
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

        // Array count
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

        // Query new
        const QueryNewWrapper = struct {
            fn call(bytes: ?[*]const u8, len: usize) callconv(.c) ?*QH {
                return QH.init(bytes, len);
            }
        };
        @export(
            &QueryNewWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_new", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Query free
        const QueryFreeWrapper = struct {
            fn call(handle: ?*QH) callconv(.c) void {
                QH.deinit(handle);
            }
        };
        @export(
            &QueryFreeWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_free", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Filter u64
        const FilterU64Wrapper = struct {
            fn call(handle: ?*QH, field: ?[*:0]const u8, cmp: c_int, value: u64) callconv(.c) c_int {
                return QH.filterU64(handle, field, cmp, value);
            }
        };
        @export(
            &FilterU64Wrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_filter_u64", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Filter i64
        const FilterI64Wrapper = struct {
            fn call(handle: ?*QH, field: ?[*:0]const u8, cmp: c_int, value: i64) callconv(.c) c_int {
                return QH.filterI64(handle, field, cmp, value);
            }
        };
        @export(
            &FilterI64Wrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_filter_i64", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Filter f32
        const FilterF32Wrapper = struct {
            fn call(handle: ?*QH, field: ?[*:0]const u8, cmp: c_int, value: f32) callconv(.c) c_int {
                return QH.filterF32(handle, field, cmp, value);
            }
        };
        @export(
            &FilterF32Wrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_filter_f32", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Filter f64
        const FilterF64Wrapper = struct {
            fn call(handle: ?*QH, field: ?[*:0]const u8, cmp: c_int, value: f64) callconv(.c) c_int {
                return QH.filterF64(handle, field, cmp, value);
            }
        };
        @export(
            &FilterF64Wrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_filter_f64", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Filter bool
        const FilterBoolWrapper = struct {
            fn call(handle: ?*QH, field: ?[*:0]const u8, cmp: c_int, value: bool) callconv(.c) c_int {
                return QH.filterBool(handle, field, cmp, value);
            }
        };
        @export(
            &FilterBoolWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_filter_bool", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Limit
        const LimitWrapper = struct {
            fn call(handle: ?*QH, limit_val: usize) callconv(.c) c_int {
                return QH.setLimit(handle, limit_val);
            }
        };
        @export(
            &LimitWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_limit", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Offset
        const OffsetWrapper = struct {
            fn call(handle: ?*QH, offset_val: usize) callconv(.c) c_int {
                return QH.setOffset(handle, offset_val);
            }
        };
        @export(
            &OffsetWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_offset", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Collect
        const CollectWrapper = struct {
            fn call(handle: ?*QH, out_count: ?*usize) callconv(.c) ?[*]T {
                return QH.collect(handle, out_count);
            }
        };
        @export(
            &CollectWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_collect", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Count
        const CountWrapper = struct {
            fn call(handle: ?*QH) callconv(.c) u64 {
                return QH.count(handle);
            }
        };
        @export(
            &CountWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_count", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Iterator start
        const IterStartWrapper = struct {
            fn call(handle: ?*QH) callconv(.c) c_int {
                return QH.iterStart(handle);
            }
        };
        @export(
            &IterStartWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_iter_start", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Iterator next
        const IterNextWrapper = struct {
            fn call(handle: ?*QH) callconv(.c) ?*const T {
                return QH.iterNext(handle);
            }
        };
        @export(
            &IterNextWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_iter_next", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Iterator reset
        const IterResetWrapper = struct {
            fn call(handle: ?*QH) callconv(.c) void {
                QH.iterReset(handle);
            }
        };
        @export(
            &IterResetWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_query_iter_reset", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Introspection: field count
        const field_infos = comptime generateFieldInfo(T);
        const FieldCountWrapper = struct {
            fn call() callconv(.c) usize {
                return field_infos.len;
            }
        };
        @export(
            &FieldCountWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_field_count", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Introspection: field info by index
        const FieldInfoWrapper = struct {
            fn call(index: usize) callconv(.c) ?*const FieldInfo {
                if (index >= field_infos.len) return null;
                return &field_infos[index];
            }
        };
        @export(
            &FieldInfoWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_field_info", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Introspection: field by name
        const FieldByNameWrapper = struct {
            fn call(name: ?[*:0]const u8) callconv(.c) ?*const FieldInfo {
                const n = name orelse return null;
                const name_len = std.mem.len(n);

                for (field_infos) |*info| {
                    const info_name_len = std.mem.len(info.name);
                    if (info_name_len == name_len) {
                        if (std.mem.eql(u8, info.name[0..info_name_len], n[0..name_len])) {
                            return info;
                        }
                    }
                }
                return null;
            }
        };
        @export(
            &FieldByNameWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_field_by_name", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Introspection: struct size
        const StructSizeWrapper = struct {
            fn call() callconv(.c) usize {
                return @sizeOf(T);
            }
        };
        @export(
            &StructSizeWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_struct_size", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );
    }
}

/// Generate the list of exported symbol names for a registry.
/// Use this when configuring export_symbol_names on your library module in build.zig.
pub fn getExportNames(comptime registry: []const SchemaDescriptor) []const []const u8 {
    // 25 functions per schema + 2 global error functions
    const funcs_per_schema = 25;
    comptime var names: [registry.len * funcs_per_schema + 2][]const u8 = undefined;

    // Global error functions
    names[0] = "zdl_last_error";
    names[1] = "zdl_error_message";

    inline for (registry, 0..) |entry, i| {
        const base = i * funcs_per_schema + 2;
        names[base + 0] = std.fmt.comptimePrint("{s}_serialize", .{entry.c_prefix});
        names[base + 1] = std.fmt.comptimePrint("{s}_deserialize", .{entry.c_prefix});
        names[base + 2] = std.fmt.comptimePrint("{s}_free", .{entry.c_prefix});
        names[base + 3] = std.fmt.comptimePrint("{s}_serialize_array", .{entry.c_prefix});
        names[base + 4] = std.fmt.comptimePrint("{s}_array_count", .{entry.c_prefix});
        names[base + 5] = std.fmt.comptimePrint("{s}_query_new", .{entry.c_prefix});
        names[base + 6] = std.fmt.comptimePrint("{s}_query_free", .{entry.c_prefix});
        names[base + 7] = std.fmt.comptimePrint("{s}_query_filter_u64", .{entry.c_prefix});
        names[base + 8] = std.fmt.comptimePrint("{s}_query_filter_i64", .{entry.c_prefix});
        names[base + 9] = std.fmt.comptimePrint("{s}_query_filter_f32", .{entry.c_prefix});
        names[base + 10] = std.fmt.comptimePrint("{s}_query_filter_f64", .{entry.c_prefix});
        names[base + 11] = std.fmt.comptimePrint("{s}_query_filter_bool", .{entry.c_prefix});
        names[base + 12] = std.fmt.comptimePrint("{s}_query_limit", .{entry.c_prefix});
        names[base + 13] = std.fmt.comptimePrint("{s}_query_offset", .{entry.c_prefix});
        names[base + 14] = std.fmt.comptimePrint("{s}_query_collect", .{entry.c_prefix});
        names[base + 15] = std.fmt.comptimePrint("{s}_query_count", .{entry.c_prefix});
        names[base + 16] = std.fmt.comptimePrint("{s}_query_iter_start", .{entry.c_prefix});
        names[base + 17] = std.fmt.comptimePrint("{s}_query_iter_next", .{entry.c_prefix});
        names[base + 18] = std.fmt.comptimePrint("{s}_query_iter_reset", .{entry.c_prefix});
        names[base + 19] = std.fmt.comptimePrint("{s}_field_count", .{entry.c_prefix});
        names[base + 20] = std.fmt.comptimePrint("{s}_field_info", .{entry.c_prefix});
        names[base + 21] = std.fmt.comptimePrint("{s}_field_by_name", .{entry.c_prefix});
        names[base + 22] = std.fmt.comptimePrint("{s}_struct_size", .{entry.c_prefix});
        // Reserve slots for future use
        names[base + 23] = std.fmt.comptimePrint("{s}_reserved1", .{entry.c_prefix});
        names[base + 24] = std.fmt.comptimePrint("{s}_reserved2", .{entry.c_prefix});
    }
    const final = names;
    return &final;
}
