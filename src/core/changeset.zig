const std = @import("std");

pub const ChangesetError = error{
    ValidationFailed,
    FieldNotFound,
    TypeMismatch,
    TooManyFields,
    TooManyErrors,
} || std.mem.Allocator.Error;

pub const MAX_FIELDS: u32 = 256;
pub const MAX_ERRORS: u32 = 64;

pub const ValidationError = struct {
    field: []const u8,
    message: []const u8,
};

pub const FieldValue = union(enum) {
    u8_val: u8,
    u16_val: u16,
    u32_val: u32,
    u64_val: u64,
    i8_val: i8,
    i16_val: i16,
    i32_val: i32,
    i64_val: i64,
    f32_val: f32,
    f64_val: f64,
    bool_val: bool,
    bytes_val: []u8,

    pub fn deinit(self: *FieldValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .bytes_val => allocator.free(self.bytes_val),
            else => {},
        }
        self.* = .{ .bool_val = false };
    }
};

inline fn sliceName(name: [:0]const u8) []const u8 {
    return std.mem.sliceTo(name, 0);
}

fn typeHasField(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasField(T, name),
        .pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
            .@"struct" => @hasField(ptr_info.child, name),
            else => false,
        },
        else => false,
    };
}

fn normalizeFieldName(comptime raw: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(raw))) {
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => comptime sliceName(raw[0..]),
            .slice => raw,
            else => @compileError("unsupported field name representation"),
        },
        .array => comptime sliceName(raw[0..]),
        else => @compileError("field name must be string literal or slice"),
    };
}

fn numericFromField(value: FieldValue) ChangesetError!f64 {
    return switch (value) {
        .u8_val => |v| @floatFromInt(v),
        .u16_val => |v| @floatFromInt(v),
        .u32_val => |v| @floatFromInt(v),
        .u64_val => |v| @floatFromInt(v),
        .i8_val => |v| @floatFromInt(v),
        .i16_val => |v| @floatFromInt(v),
        .i32_val => |v| @floatFromInt(v),
        .i64_val => |v| @floatFromInt(v),
        .f32_val => |v| @floatCast(v),
        .f64_val => |v| v,
        else => return error.TypeMismatch,
    };
}

fn convertValue(value: anytype, allocator: std.mem.Allocator) ChangesetError!FieldValue {
    return switch (@typeInfo(@TypeOf(value))) {
        .int => |int_info| switch (int_info.signedness) {
            .unsigned => switch (int_info.bits) {
                8 => .{ .u8_val = @intCast(value) },
                16 => .{ .u16_val = @intCast(value) },
                32 => .{ .u32_val = @intCast(value) },
                64 => .{ .u64_val = @intCast(value) },
                else => return error.TypeMismatch,
            },
            .signed => switch (int_info.bits) {
                8 => .{ .i8_val = @intCast(value) },
                16 => .{ .i16_val = @intCast(value) },
                32 => .{ .i32_val = @intCast(value) },
                64 => .{ .i64_val = @intCast(value) },
                else => return error.TypeMismatch,
            },
        },
        .float => |float_info| switch (float_info.bits) {
            32 => .{ .f32_val = @floatCast(value) },
            64 => .{ .f64_val = @floatCast(value) },
            else => return error.TypeMismatch,
        },
        .bool => .{ .bool_val = value },
        .array => |arr_info| if (arr_info.child == u8) blk: {
            const duped = try allocator.dupe(u8, value[0..]);
            break :blk .{ .bytes_val = duped };
        } else return error.TypeMismatch,
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => if (ptr_info.child == u8) blk: {
                const duped = try allocator.dupe(u8, value);
                break :blk .{ .bytes_val = duped };
            } else return error.TypeMismatch,
            .one => switch (@typeInfo(ptr_info.child)) {
                .array => |arr_info| if (arr_info.child == u8) blk: {
                    const sentinel_slice = value[0..];
                    const trimmed = std.mem.sliceTo(sentinel_slice, 0);
                    const duped = try allocator.dupe(u8, trimmed);
                    break :blk .{ .bytes_val = duped };
                } else return error.TypeMismatch,
                else => return error.TypeMismatch,
            },
            else => return error.TypeMismatch,
        },
        else => return error.TypeMismatch,
    };
}

fn setField(
    comptime T: type,
    result: *T,
    comptime field: std.builtin.Type.StructField,
    value: FieldValue,
) ChangesetError!void {
    const field_name = comptime sliceName(field.name);
    switch (@typeInfo(field.type)) {
        .int => |int_info| switch (int_info.signedness) {
            .unsigned => switch (int_info.bits) {
                8 => @field(result, field_name) = switch (value) {
                    .u8_val => |v| v,
                    else => return ChangesetError.TypeMismatch,
                },
                16 => @field(result, field_name) = switch (value) {
                    .u16_val => |v| v,
                    else => return ChangesetError.TypeMismatch,
                },
                32 => @field(result, field_name) = switch (value) {
                    .u32_val => |v| v,
                    else => return ChangesetError.TypeMismatch,
                },
                64 => @field(result, field_name) = switch (value) {
                    .u64_val => |v| v,
                    else => return ChangesetError.TypeMismatch,
                },
                else => return ChangesetError.TypeMismatch,
            },
            .signed => switch (int_info.bits) {
                8 => @field(result, field_name) = switch (value) {
                    .i8_val => |v| v,
                    else => return ChangesetError.TypeMismatch,
                },
                16 => @field(result, field_name) = switch (value) {
                    .i16_val => |v| v,
                    else => return ChangesetError.TypeMismatch,
                },
                32 => @field(result, field_name) = switch (value) {
                    .i32_val => |v| v,
                    else => return ChangesetError.TypeMismatch,
                },
                64 => @field(result, field_name) = switch (value) {
                    .i64_val => |v| v,
                    else => return ChangesetError.TypeMismatch,
                },
                else => return ChangesetError.TypeMismatch,
            },
        },
        .float => |float_info| switch (float_info.bits) {
            32 => @field(result, field_name) = switch (value) {
                .f32_val => |v| v,
                else => return ChangesetError.TypeMismatch,
            },
            64 => @field(result, field_name) = switch (value) {
                .f64_val => |v| v,
                else => return ChangesetError.TypeMismatch,
            },
            else => return ChangesetError.TypeMismatch,
        },
        .bool => @field(result, field_name) = switch (value) {
            .bool_val => |v| v,
            else => return ChangesetError.TypeMismatch,
        },
        .array => |arr_info| if (arr_info.child == u8) {
            const dest = @field(result, field_name)[0..];
            const src = switch (value) {
                .bytes_val => |bytes| bytes,
                else => return ChangesetError.TypeMismatch,
            };
            if (src.len > dest.len) return ChangesetError.ValidationFailed;
            std.mem.copyForwards(u8, dest[0..src.len], src);
            @memset(dest[src.len..], 0);
        } else return ChangesetError.TypeMismatch,
        else => return ChangesetError.TypeMismatch,
    }
}

pub fn Changeset(comptime T: type) type {
    return struct {
        const Self = @This();
        changes: std.StringHashMap(FieldValue),
        errors: std.ArrayListUnmanaged(ValidationError),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .changes = std.StringHashMap(FieldValue).init(allocator),
                .errors = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.changes.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.changes.deinit();
            self.errors.deinit(self.allocator);
        }

        pub fn valid(self: *const Self) bool {
            return self.errors.items.len == 0;
        }

        pub fn apply(self: *const Self) ChangesetError!T {
            if (!self.valid()) return error.ValidationFailed;
            var result: T = undefined;

            inline for (std.meta.fields(T)) |field| {
                const field_name = comptime sliceName(field.name);
                if (self.changes.get(field_name)) |value| {
                    try setField(T, &result, field, value);
                } else if (field.defaultValue()) |default_value| {
                    @field(result, field_name) = default_value;
                } else {
                    return error.FieldNotFound;
                }
            }

            return result;
        }

        pub fn cast(
            self: *Self,
            params: anytype,
            comptime field_names: []const []const u8,
        ) ChangesetError!void {
            if (field_names.len > MAX_FIELDS) return error.TooManyFields;

            const ParamsType = @TypeOf(params);
            inline for (field_names) |name| {
                const field_name = comptime normalizeFieldName(name);
                if (!comptime typeHasField(T, field_name)) return error.FieldNotFound;
                if (!comptime typeHasField(ParamsType, field_name)) continue;

                if (!self.changes.contains(field_name) and self.changes.count() >= MAX_FIELDS) {
                    return error.TooManyFields;
                }

                const value = try convertValue(@field(params, field_name), self.allocator);

                if (self.changes.getPtr(field_name)) |existing| {
                    existing.deinit(self.allocator);
                    existing.* = value;
                } else {
                    try self.changes.put(field_name, value);
                }
            }
        }

        pub fn validateRequired(
            self: *Self,
            comptime field_names: []const []const u8,
        ) ChangesetError!void {
            inline for (field_names) |name| {
                const field_name = comptime normalizeFieldName(name);
                if (!self.changes.contains(field_name)) {
                    try self.addError(field_name, "is required");
                }
            }
        }

        pub fn validateLength(
            self: *Self,
            field_name: []const u8,
            opts: struct {
                min: ?usize = null,
                max: ?usize = null,
            },
        ) ChangesetError!void {
            const entry = self.changes.get(field_name) orelse return error.FieldNotFound;
            const len = switch (entry) {
                .bytes_val => |bytes| bytes.len,
                else => return error.TypeMismatch,
            };
            if (opts.min) |min_len| {
                if (len < min_len) try self.addError(field_name, "is too short");
            }
            if (opts.max) |max_len| {
                if (len > max_len) try self.addError(field_name, "is too long");
            }
        }

        pub fn validateNumber(
            self: *Self,
            field_name: []const u8,
            opts: struct {
                min: ?f64 = null,
                max: ?f64 = null,
                greater_than: ?f64 = null,
                less_than: ?f64 = null,
            },
        ) ChangesetError!void {
            const entry = self.changes.get(field_name) orelse return error.FieldNotFound;
            const numeric = try numericFromField(entry);

            if (opts.min) |min_value| {
                if (numeric < min_value) try self.addError(field_name, "is below minimum");
            }
            if (opts.max) |max_value| {
                if (numeric > max_value) try self.addError(field_name, "is above maximum");
            }
            if (opts.greater_than) |gt| {
                if (!(numeric > gt)) try self.addError(field_name, "must be greater");
            }
            if (opts.less_than) |lt| {
                if (!(numeric < lt)) try self.addError(field_name, "must be less");
            }
        }

        fn addError(
            self: *Self,
            field: []const u8,
            message: []const u8,
        ) ChangesetError!void {
            if (self.errors.items.len >= MAX_ERRORS) return error.TooManyErrors;
            try self.errors.append(self.allocator, .{
                .field = field,
                .message = message,
            });
        }
    };
}
