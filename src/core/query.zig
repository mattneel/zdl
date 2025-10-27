const std = @import("std");
const format = @import("format.zig");
const schema = @import("schema.zig");
const crc32 = @import("crc.zig");
const Target = @import("target.zig").Target;

pub const QueryError = error{
    InvalidData,
    LimitRequired,
    TooManyResults,
    TooManyFilters,
    FieldNotFound,
    UnsupportedFieldType,
    TypeMismatch,
} || std.mem.Allocator.Error;

pub const MAX_RESULTS: u32 = 1_000_000;
pub const MAX_FILTER_DEPTH: u32 = 8;

pub const Operator = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
};

pub fn QueryBuilder(comptime T: type) type {
    comptime schema.ensure(T);

    return struct {
        const Self = @This();
        const FieldEnum = std.meta.FieldEnum(T);

        const FilterValue = union(enum) {
            u64_val: u64,
            i64_val: i64,
            f32_val: f32,
            f64_val: f64,
        };

        const FilterTag = std.meta.Tag(FilterValue);

        const Filter = struct {
            field_tag: FieldEnum,
            op: Operator,
            tag: FilterTag,
            value: FilterValue,
        };

        const Layout = struct {
            prepared: bool = false,
            data_start: usize = 0,
            data_end: usize = 0,
            item_size: usize = @sizeOf(T),
            total_items: u64 = 0,
        };

        bytes: []const u8,
        allocator: std.mem.Allocator,
        limit_value: ?u32,
        filters: std.ArrayListUnmanaged(Filter),
        layout: Layout,

        pub fn init(bytes: []const u8, allocator: std.mem.Allocator) Self {
            return .{
                .bytes = bytes,
                .allocator = allocator,
                .limit_value = null,
                .filters = .{},
                .layout = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.filters.deinit(self.allocator);
        }

        pub fn limit(self: *Self, n: u32) *Self {
            const capped: u32 = if (n > MAX_RESULTS) MAX_RESULTS else n;
            self.limit_value = capped;
            return self;
        }

        pub fn filter(
            self: *Self,
            field_name: []const u8,
            op: Operator,
            value: anytype,
        ) QueryError!*Self {
            if (self.filters.items.len >= MAX_FILTER_DEPTH) {
                return error.TooManyFilters;
            }

            const field_tag = std.meta.stringToEnum(FieldEnum, field_name) orelse return error.FieldNotFound;
            const tag = fieldTagForEnum(field_tag) orelse return error.UnsupportedFieldType;
            const coerced = try coerceFilterValue(value, tag);

            try self.filters.append(self.allocator, .{
                .field_tag = field_tag,
                .op = op,
                .tag = tag,
                .value = coerced,
            });
            return self;
        }

        pub fn clearFilters(self: *Self) *Self {
            self.filters.clearRetainingCapacity();
            return self;
        }

        pub fn iter(self: *Self) QueryError!Iterator {
            try self.ensureLayout();
            return Iterator{
                .query = self,
                .offset = self.layout.data_start,
                .yielded = 0,
            };
        }

        pub fn collect(self: *Self) QueryError![]const T {
            if (self.limit_value == null) return error.LimitRequired;
            try self.ensureLayout();

            var results = std.ArrayListUnmanaged(T){};
            errdefer results.deinit(self.allocator);

            var it = try self.iter();
            while (it.next()) |item| {
                try results.append(self.allocator, item.*);
            }

            const owned = try results.toOwnedSlice(self.allocator);
            return owned;
        }

        pub const Iterator = struct {
            query: *Self,
            offset: usize,
            yielded: u32,

            pub fn next(self: *Iterator) ?*const T {
                const layout = self.query.layout;
                const limit_value = self.query.limit_value;
                const bytes = self.query.bytes;

                while (self.offset < layout.data_end) {
                    if (self.yielded >= MAX_RESULTS) return null;
                    if (limit_value) |lim| {
                        if (self.yielded >= lim) return null;
                    }
                    if (layout.data_end - self.offset < layout.item_size) {
                        return null;
                    }

                    const slice = bytes[self.offset .. self.offset + layout.item_size];
                    const ptr = @as(*const T, @ptrCast(@alignCast(slice.ptr)));
                    self.offset += layout.item_size;

                    if (!matchesFilters(ptr, self.query.filters.items)) {
                        continue;
                    }

                    self.yielded += 1;
                    return ptr;
                }

                return null;
            }
        };

        fn ensureLayout(self: *Self) QueryError!void {
            if (self.layout.prepared) return;

            const header_len = @as(usize, format.HEADER_SIZE);
            if (self.bytes.len < header_len) {
                return error.InvalidData;
            }

            const header = format.validateHeader(self.bytes[0..header_len]) catch return error.InvalidData;
            if (header.target != @intFromEnum(Target.cpu)) {
                return error.InvalidData;
            }

            const payload_len = std.math.cast(usize, header.length) orelse return error.InvalidData;
            const actual_payload = self.bytes.len - header_len;

            const item_size = @sizeOf(T);
            const item_size_u64 = std.math.cast(u64, item_size) orelse return error.InvalidData;

            if (actual_payload != payload_len and actual_payload != payload_len + 8) {
                return error.InvalidData;
            }

            if (actual_payload == payload_len) {
                if (payload_len != item_size) {
                    return error.InvalidData;
                }
                self.layout.data_start = header_len;
                self.layout.data_end = header_len + payload_len;
                self.layout.total_items = 1;
            } else {
                const count = format.arrayCount(self.bytes) catch return error.InvalidData;
                const expected_bytes = std.math.mul(u64, item_size_u64, count) catch return error.InvalidData;
                if (expected_bytes != header.length) {
                    return error.InvalidData;
                }
                const expected_len = std.math.cast(usize, expected_bytes) orelse return error.InvalidData;
                self.layout.data_start = header_len + 8;
                self.layout.data_end = self.layout.data_start + expected_len;
                self.layout.total_items = count;
            }

            if (self.layout.total_items > MAX_RESULTS) {
                return error.TooManyResults;
            }

            if ((self.layout.data_start & (@alignOf(T) - 1)) != 0) {
                return error.InvalidData;
            }

            const payload = self.bytes[self.layout.data_start..self.layout.data_end];
            const checksum = crc32.compute(payload);
            if (checksum != header.checksum) {
                return error.InvalidData;
            }

            self.layout.item_size = item_size;
            self.layout.prepared = true;
        }

        fn matchesFilters(item: *const T, filters: []const Filter) bool {
            for (filters) |f| {
                if (!matchesFilter(item, f)) return false;
            }
            return true;
        }

        fn matchesFilter(item: *const T, flt: Filter) bool {
            const field_value = readFieldValue(item, flt);
            return switch (flt.op) {
                .eq => fieldEquals(field_value, flt.value),
                .ne => !fieldEquals(field_value, flt.value),
                .lt => fieldLessThan(field_value, flt.value),
                .le => fieldLessThan(field_value, flt.value) or fieldEquals(field_value, flt.value),
                .gt => !fieldLessThan(field_value, flt.value) and !fieldEquals(field_value, flt.value),
                .ge => !fieldLessThan(field_value, flt.value),
            };
        }

        fn readFieldValue(item: *const T, flt: Filter) FilterValue {
            inline for (std.meta.fields(T)) |field| {
                if (@field(FieldEnum, field.name) == flt.field_tag) {
                    const value = @field(item.*, field.name);
                    return packFieldValue(field.type, value, flt.tag);
                }
            }
            @panic("Field tag not found");
        }

        fn fieldTagForEnum(field_tag: FieldEnum) ?FilterTag {
            inline for (std.meta.fields(T)) |field| {
                if (@field(FieldEnum, field.name) == field_tag) {
                    return filterTagForType(field.type);
                }
            }
            return null;
        }

        fn filterTagForType(comptime FieldType: type) ?FilterTag {
            return switch (@typeInfo(FieldType)) {
                .int => |info| switch (info.signedness) {
                    .signed => FilterTag.i64_val,
                    .unsigned => FilterTag.u64_val,
                },
                .float => |info| switch (info.bits) {
                    32 => FilterTag.f32_val,
                    64 => FilterTag.f64_val,
                    else => null,
                },
                else => null,
            };
        }

        fn coerceFilterValue(value: anytype, tag: FilterTag) QueryError!FilterValue {
            const ValueType = @TypeOf(value);
            return switch (tag) {
                .u64_val => switch (@typeInfo(ValueType)) {
                    .int, .comptime_int => {
                        const casted = std.math.cast(u64, value) orelse return error.TypeMismatch;
                        return FilterValue{ .u64_val = casted };
                    },
                    else => return error.TypeMismatch,
                },
                .i64_val => switch (@typeInfo(ValueType)) {
                    .int, .comptime_int => {
                        const casted = std.math.cast(i64, value) orelse return error.TypeMismatch;
                        return FilterValue{ .i64_val = casted };
                    },
                    else => return error.TypeMismatch,
                },
                .f32_val => switch (@typeInfo(ValueType)) {
                    .float, .comptime_float => {
                        const casted: f32 = @floatCast(value);
                        return FilterValue{ .f32_val = casted };
                    },
                    .int, .comptime_int => {
                        const casted: f32 = @floatFromInt(value);
                        return FilterValue{ .f32_val = casted };
                    },
                    else => return error.TypeMismatch,
                },
                .f64_val => switch (@typeInfo(ValueType)) {
                    .float, .comptime_float => {
                        const casted: f64 = @floatCast(value);
                        return FilterValue{ .f64_val = casted };
                    },
                    .int, .comptime_int => {
                        const casted: f64 = @floatFromInt(value);
                        return FilterValue{ .f64_val = casted };
                    },
                    else => return error.TypeMismatch,
                },
            };
        }

        fn packFieldValue(comptime FieldType: type, value: FieldType, tag: FilterTag) FilterValue {
            return switch (@typeInfo(FieldType)) {
                .int => |info| switch (info.signedness) {
                    .unsigned => blk: {
                        if (tag != .u64_val) @panic("filter tag mismatch");
                        const casted: u64 = @intCast(value);
                        break :blk FilterValue{ .u64_val = casted };
                    },
                    .signed => blk: {
                        if (tag != .i64_val) @panic("filter tag mismatch");
                        const casted: i64 = @intCast(value);
                        break :blk FilterValue{ .i64_val = casted };
                    },
                },
                .float => |info| switch (info.bits) {
                    32 => blk: {
                        if (tag != .f32_val) @panic("filter tag mismatch");
                        break :blk FilterValue{ .f32_val = value };
                    },
                    64 => blk: {
                        if (tag != .f64_val) @panic("filter tag mismatch");
                        break :blk FilterValue{ .f64_val = value };
                    },
                    else => @panic("unsupported field type"),
                },
                else => @panic("unsupported field type"),
            };
        }

        fn fieldEquals(a: FilterValue, b: FilterValue) bool {
            return switch (a) {
                .u64_val => |av| switch (b) {
                    .u64_val => av == b.u64_val,
                    else => false,
                },
                .i64_val => |av| switch (b) {
                    .i64_val => av == b.i64_val,
                    else => false,
                },
                .f32_val => |av| switch (b) {
                    .f32_val => av == b.f32_val,
                    else => false,
                },
                .f64_val => |av| switch (b) {
                    .f64_val => av == b.f64_val,
                    else => false,
                },
            };
        }

        fn fieldLessThan(a: FilterValue, b: FilterValue) bool {
            return switch (a) {
                .u64_val => |av| switch (b) {
                    .u64_val => av < b.u64_val,
                    else => false,
                },
                .i64_val => |av| switch (b) {
                    .i64_val => av < b.i64_val,
                    else => false,
                },
                .f32_val => |av| switch (b) {
                    .f32_val => av < b.f32_val,
                    else => false,
                },
                .f64_val => |av| switch (b) {
                    .f64_val => av < b.f64_val,
                    else => false,
                },
            };
        }
    };
}

pub fn query(
    comptime T: type,
    bytes: []const u8,
    allocator: std.mem.Allocator,
) QueryBuilder(T) {
    return QueryBuilder(T).init(bytes, allocator);
}
