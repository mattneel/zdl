const std = @import("std");
const builtin = @import("builtin");
const zdl = @import("../root.zig");
const c_error = @import("c_error.zig");

const Target = zdl.Target;
const query_mod = zdl.query;

// ---------------------------------------------------------------------------
// Allocation across the C ABI boundary.
//
// Hosted targets use libc malloc/free, so `{prefix}_free(ptr)` is plain
// free() and callers can mix zdl allocations with their own malloc
// discipline. Freestanding targets (wasm32-freestanding in particular) have
// no libc: allocations are prefixed with a hidden size header so they can
// still be freed by bare pointer, preserving the same C contract.
// ---------------------------------------------------------------------------

const use_portable_alloc = builtin.os.tag == .freestanding;

/// Big enough for the maximum alignment of any exportable schema type
/// (Zig's max integer alignment on wasm32/x86_64 is 16). Layout: total
/// allocation length at [0..8], magic canary at [8..16].
const portable_header = 16;

/// Canary stamped into every headered allocation. freeAlloc asserts it in
/// safety-checked builds to catch foreign pointers and double-frees before
/// a bogus length reaches the backing allocator. NOTE: in release builds a
/// foreign pointer passed to {prefix}_free/zdl_free silently corrupts the
/// allocator (libc free aborts; WasmAllocator cannot detect misuse) — only
/// pass pointers that zdl returned, exactly once.
const portable_magic: u64 = 0x7A_64_6C_61_6C_6C_6F_63; // "zdlalloc"

const portable_backing: std.mem.Allocator = blk: {
    if (!builtin.target.cpu.arch.isWasm()) {
        @compileError("zdl C API on freestanding targets requires wasm32/wasm64");
    }
    break :blk std.heap.wasm_allocator;
};

fn portableAllocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    std.debug.assert(alignment.toByteUnits() <= portable_header);
    const total = std.math.add(usize, portable_header, len) catch return null;
    const base = portable_backing.rawAlloc(
        total,
        comptime std.mem.Alignment.fromByteUnits(portable_header),
        ret_addr,
    ) orelse return null;
    std.mem.writeInt(usize, base[0..@sizeOf(usize)], total, .little);
    std.mem.writeInt(u64, base[8..16], portable_magic, .little);
    return base + portable_header;
}

fn portableResizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return false; // headered allocations never resize in place
}

fn portableRemapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

fn portableFreeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = alignment;
    const base = memory.ptr - portable_header;
    // Depends on a std invariant: Allocator.free (and the realloc fallback,
    // since resize/remap always decline here) is always called with the exact
    // length the allocation was created with, so the stored header matches.
    const total = portable_header + memory.len;
    std.debug.assert(std.mem.readInt(usize, base[0..@sizeOf(usize)], .little) == total);
    std.debug.assert(std.mem.readInt(u64, base[8..16], .little) == portable_magic);
    portable_backing.rawFree(
        base[0..total],
        comptime std.mem.Alignment.fromByteUnits(portable_header),
        ret_addr,
    );
}

const portable_vtable = std.mem.Allocator.VTable{
    .alloc = portableAllocFn,
    .resize = portableResizeFn,
    .remap = portableRemapFn,
    .free = portableFreeFn,
};

const portable_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &portable_vtable,
};

const allocator: std.mem.Allocator = if (use_portable_alloc) portable_allocator else std.heap.c_allocator;

/// malloc-style allocation usable from C/wasm hosts; freed with `freeAlloc`
/// (i.e. `{prefix}_free` / `zdl_free`).
pub fn rawAlloc(size: usize) ?*anyopaque {
    if (comptime use_portable_alloc) {
        const mem = allocator.rawAlloc(
            size,
            comptime std.mem.Alignment.fromByteUnits(portable_header),
            @returnAddress(),
        ) orelse return null;
        return @ptrCast(mem);
    }
    return std.c.malloc(size);
}

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
    c_error.clearError();
    const ptr = value orelse {
        c_error.setError(.null_param);
        return null;
    };
    const out_len_ptr = out_len orelse {
        c_error.setError(.null_param);
        return null;
    };
    const target_enum = toTarget(target) orelse {
        c_error.setError(.unsupported_type);
        return null;
    };

    const bytes = zdl.serialize.serialize(ptr.*, target_enum, allocator) catch |err| {
        c_error.setError(switch (err) {
            error.UnsupportedTarget => .unsupported_type,
            error.DataTooLarge => .data_too_large,
            error.OutOfMemory => .out_of_memory,
            else => .buffer_corrupt,
        });
        return null;
    };

    out_len_ptr.* = bytes.len;
    return @constCast(bytes.ptr);
}

pub fn serializeIntoForType(
    comptime T: type,
    value: ?*const T,
    dest: ?[*]u8,
    dest_len: usize,
    target: c_int,
    out_len: ?*usize,
) c_int {
    c_error.clearError();

    const ptr = value orelse {
        c_error.setError(.null_param);
        return @intFromEnum(Error.null_param);
    };
    const dest_ptr = dest orelse {
        c_error.setError(.null_param);
        return @intFromEnum(Error.null_param);
    };
    const out_len_ptr = out_len orelse {
        c_error.setError(.null_param);
        return @intFromEnum(Error.null_param);
    };
    const target_enum = toTarget(target) orelse {
        c_error.setError(.unsupported_type);
        return @intFromEnum(Error.unsupported_type);
    };

    const written = zdl.serialize.serializeInto(dest_ptr[0..dest_len], ptr.*, target_enum) catch |err| {
        const code: Error = switch (err) {
            error.BufferTooSmall => .buffer_too_small,
            error.UnsupportedTarget => .unsupported_type,
            error.DataTooLarge => .data_too_large,
            else => .buffer_corrupt,
        };
        c_error.setError(code);
        return @intFromEnum(code);
    };
    out_len_ptr.* = written.len;
    return @intFromEnum(Error.ok);
}

pub fn serializedSizeForType(comptime T: type, target: c_int) usize {
    const target_enum = toTarget(target) orelse return 0;
    return zdl.serialize.serializedSize(T, target_enum);
}

pub fn deserializeForType(comptime T: type, bytes: ?[*]const u8, len: usize) ?*T {
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

    const value = zdl.deserialize.deserialize(T, slice, allocator) catch |err| {
        c_error.setError(switch (err) {
            error.ChecksumMismatch => .checksum_mismatch,
            error.UnsupportedTarget => .unsupported_type,
            error.DataTooLarge => .data_too_large,
            else => .buffer_corrupt, // size/truncation/format/magic errors
        });
        return null;
    };

    comptime std.debug.assert(@alignOf(T) <= portable_header);
    const mem = rawAlloc(@sizeOf(T)) orelse {
        c_error.setError(.out_of_memory);
        return null;
    };
    const typed: *T = @ptrCast(@alignCast(mem));
    typed.* = value;
    return typed;
}

pub fn serializeArrayForType(comptime T: type, items: ?[*]const T, count: usize, target: c_int, out_len: ?*usize) ?[*]u8 {
    c_error.clearError();
    const out_len_ptr = out_len orelse {
        c_error.setError(.null_param);
        return null;
    };
    const target_enum = toTarget(target) orelse {
        c_error.setError(.unsupported_type);
        return null;
    };

    const slice: []const T = if (count == 0) &[_]T{} else blk: {
        const ptr = items orelse {
            c_error.setError(.null_param);
            return null;
        };
        break :blk ptr[0..count];
    };

    const bytes = zdl.format.serializeArray(T, slice, target_enum, allocator) catch |err| {
        c_error.setError(switch (err) {
            error.UnsupportedTarget => .unsupported_type,
            error.DataTooLarge => .data_too_large,
            error.OutOfMemory => .out_of_memory,
            else => .buffer_corrupt,
        });
        return null;
    };

    out_len_ptr.* = bytes.len;
    return @constCast(bytes.ptr);
}

pub fn arrayCountFromBytes(bytes: ?[*]const u8, len: usize) u64 {
    c_error.clearError();
    if (len == 0) {
        c_error.setError(.null_param);
        return 0;
    }
    const ptr = bytes orelse {
        c_error.setError(.null_param);
        return 0;
    };
    const slice = ptr[0..len];
    return zdl.format.arrayCount(slice) catch {
        c_error.setError(.buffer_corrupt);
        return 0;
    };
}

pub fn freeAlloc(ptr: ?*anyopaque) void {
    const p = ptr orelse return;
    if (comptime use_portable_alloc) {
        const user: [*]u8 = @ptrCast(p);
        const base = user - portable_header;
        const total = std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
        // catches foreign pointers / double-frees in safety-checked builds
        std.debug.assert(std.mem.readInt(u64, base[8..16], .little) == portable_magic);
        portable_backing.rawFree(
            base[0..total],
            comptime std.mem.Alignment.fromByteUnits(portable_header),
            @returnAddress(),
        );
    } else {
        std.c.free(p);
    }
}

fn zdlAllocExport(size: usize) callconv(.c) ?[*]u8 {
    return @ptrCast(rawAlloc(size));
}

fn zdlFreeExport(ptr: ?*anyopaque) callconv(.c) void {
    freeAlloc(ptr);
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

            comptime std.debug.assert(@alignOf(Self) <= portable_header);
            const mem = rawAlloc(@sizeOf(Self)) orelse {
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
            freeAlloc(@ptrCast(handle));
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

/// Mutable container handle wrapper for C API. Wraps
/// zdl.mutable.MutableContainer plus an optional iterator. Pointers handed
/// out by get/iter_next point into container storage and are invalidated by
/// the relocation fences (compact, reserve); after a fence, iter_next
/// reports stale_view and get must be re-called.
pub fn MutableHandle(comptime T: type) type {
    const M = zdl.mutable.MutableContainer(T);

    return struct {
        const Self = @This();

        container: M,
        iterator: ?M.Iterator = null,

        fn create(container: M) ?*Self {
            comptime std.debug.assert(@alignOf(Self) <= portable_header);
            const mem = rawAlloc(@sizeOf(Self)) orelse {
                c_error.setError(.out_of_memory);
                return null;
            };
            const handle: *Self = @ptrCast(@alignCast(mem));
            handle.* = .{ .container = container, .iterator = null };
            return handle;
        }

        pub fn init(capacity: usize) ?*Self {
            c_error.clearError();
            const container = M.init(allocator, capacity) catch {
                c_error.setError(.out_of_memory);
                return null;
            };
            var c = container;
            return create(c) orelse {
                c.deinit();
                return null;
            };
        }

        pub fn load(bytes: ?[*]const u8, len: usize, extra_capacity: usize) ?*Self {
            c_error.clearError();
            if (len == 0) {
                c_error.setError(.null_param);
                return null;
            }
            const ptr = bytes orelse {
                c_error.setError(.null_param);
                return null;
            };
            var container = M.load(allocator, ptr[0..len], extra_capacity) catch |err| {
                c_error.setError(c_error.fromLoadError(err));
                return null;
            };
            return create(container) orelse {
                container.deinit();
                return null;
            };
        }

        pub fn deinit(self: ?*Self) void {
            const handle = self orelse return;
            handle.container.deinit();
            freeAlloc(@ptrCast(handle));
        }

        pub fn append(self: ?*Self, value: ?*const T, out_slot: ?*usize) c_int {
            c_error.clearError();
            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const value_ptr = value orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const slot = handle.container.append(value_ptr.*) catch {
                c_error.setError(.capacity_full);
                return @intFromEnum(Error.capacity_full);
            };
            if (out_slot) |out| out.* = slot;
            return @intFromEnum(Error.ok);
        }

        pub fn get(self: ?*Self, slot: usize) ?*const T {
            c_error.clearError();
            const handle = self orelse {
                c_error.setError(.null_param);
                return null;
            };
            return handle.container.get(slot) catch |err| {
                c_error.setError(switch (err) {
                    error.SlotOutOfRange => .slot_out_of_range,
                    error.Deleted => .slot_deleted,
                });
                return null;
            };
        }

        pub fn getVerified(self: ?*Self, slot: usize, out: ?*T) c_int {
            c_error.clearError();
            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const out_ptr = out orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const value = handle.container.getVerified(slot) catch |err| {
                const code: Error = switch (err) {
                    error.ChecksumMismatch => .checksum_mismatch,
                    error.SlotOutOfRange => .slot_out_of_range,
                    error.Deleted => .slot_deleted,
                };
                c_error.setError(code);
                return @intFromEnum(code);
            };
            out_ptr.* = value;
            return @intFromEnum(Error.ok);
        }

        pub fn update(self: ?*Self, slot: usize, value: ?*const T) c_int {
            c_error.clearError();
            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            const value_ptr = value orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            handle.container.update(slot, value_ptr.*) catch |err| {
                const code: Error = switch (err) {
                    error.SlotOutOfRange => .slot_out_of_range,
                    error.Deleted => .slot_deleted,
                };
                c_error.setError(code);
                return @intFromEnum(code);
            };
            return @intFromEnum(Error.ok);
        }

        pub fn del(self: ?*Self, slot: usize) c_int {
            c_error.clearError();
            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            handle.container.delete(slot) catch |err| {
                const code: Error = switch (err) {
                    error.SlotOutOfRange => .slot_out_of_range,
                    error.AlreadyDeleted => .slot_deleted,
                };
                c_error.setError(code);
                return @intFromEnum(code);
            };
            return @intFromEnum(Error.ok);
        }

        pub fn compact(self: ?*Self) void {
            c_error.clearError();
            const handle = self orelse {
                c_error.setError(.null_param);
                return;
            };
            handle.container.compact();
        }

        pub fn reserve(self: ?*Self, additional: usize) c_int {
            c_error.clearError();
            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            handle.container.reserve(additional) catch {
                c_error.setError(.out_of_memory);
                return @intFromEnum(Error.out_of_memory);
            };
            return @intFromEnum(Error.ok);
        }

        pub fn lenOf(self: ?*const Self) usize {
            const handle = self orelse return 0;
            return handle.container.len;
        }

        pub fn liveOf(self: ?*const Self) usize {
            const handle = self orelse return 0;
            return handle.container.live;
        }

        pub fn generationOf(self: ?*const Self) u64 {
            const handle = self orelse return 0;
            return handle.container.generation;
        }

        pub fn flush(self: ?*Self, out_len: ?*usize) ?[*]u8 {
            c_error.clearError();
            const handle = self orelse {
                c_error.setError(.null_param);
                return null;
            };
            const out_len_ptr = out_len orelse {
                c_error.setError(.null_param);
                return null;
            };
            const bytes = handle.container.flush(allocator) catch |err| {
                const code: Error = switch (err) {
                    error.DataTooLarge => .data_too_large,
                    error.OutOfMemory => .out_of_memory,
                };
                c_error.setError(code);
                return null;
            };
            out_len_ptr.* = bytes.len;
            return bytes.ptr;
        }

        pub fn iterStart(self: ?*Self) c_int {
            c_error.clearError();
            const handle = self orelse {
                c_error.setError(.null_param);
                return @intFromEnum(Error.null_param);
            };
            handle.iterator = handle.container.iter();
            return @intFromEnum(Error.ok);
        }

        /// Returns NULL at end of iteration OR on stale view; check
        /// zdl_last_error to distinguish (ok = end, stale_view = fence).
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
            const item = iter.next() catch {
                c_error.setError(.stale_view);
                return null;
            };
            return item;
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
/// - `{prefix}_serialize_into` - Zero-alloc serialize into a caller buffer
/// - `{prefix}_serialized_size` - Required buffer size for serialize_into
/// - `{prefix}_mut_*` - Mutable container CRUD (new/load/free/append/get/
///   get_verified/update/delete/compact/reserve/len/live/generation/flush/
///   iter_start/iter_next/iter_reset)
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
    // Host-side allocation (lets wasm/JS hosts place input buffers inside
    // linear memory; on hosted targets these are malloc/free wrappers)
    @export(&zdlAllocExport, .{
        .name = "zdl_alloc",
        .linkage = .strong,
        .visibility = .default,
    });
    @export(&zdlFreeExport, .{
        .name = "zdl_free",
        .linkage = .strong,
        .visibility = .default,
    });

    for (registry) |entry| {
        const T = entry.Type;
        const prefix = entry.c_prefix;
        const QH = QueryHandle(T);
        const MH = MutableHandle(T);

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

        // Zero-alloc serialize into caller buffer
        const SerializeIntoWrapper = struct {
            fn call(value: ?*const T, dest: ?[*]u8, dest_len: usize, target: c_int, out_len: ?*usize) callconv(.c) c_int {
                return serializeIntoForType(T, value, dest, dest_len, target, out_len);
            }
        };
        @export(
            &SerializeIntoWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_serialize_into", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Serialized size for buffer sizing
        const SerializedSizeWrapper = struct {
            fn call(target: c_int) callconv(.c) usize {
                return serializedSizeForType(T, target);
            }
        };
        @export(
            &SerializedSizeWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_serialized_size", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        // Mutable container API
        const MutNewWrapper = struct {
            fn call(capacity: usize) callconv(.c) ?*MH {
                return MH.init(capacity);
            }
        };
        @export(
            &MutNewWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_new", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutLoadWrapper = struct {
            fn call(bytes: ?[*]const u8, len: usize, extra_capacity: usize) callconv(.c) ?*MH {
                return MH.load(bytes, len, extra_capacity);
            }
        };
        @export(
            &MutLoadWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_load", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutFreeWrapper = struct {
            fn call(handle: ?*MH) callconv(.c) void {
                MH.deinit(handle);
            }
        };
        @export(
            &MutFreeWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_free", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutAppendWrapper = struct {
            fn call(handle: ?*MH, value: ?*const T, out_slot: ?*usize) callconv(.c) c_int {
                return MH.append(handle, value, out_slot);
            }
        };
        @export(
            &MutAppendWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_append", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutGetWrapper = struct {
            fn call(handle: ?*MH, slot: usize) callconv(.c) ?*const T {
                return MH.get(handle, slot);
            }
        };
        @export(
            &MutGetWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_get", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutGetVerifiedWrapper = struct {
            fn call(handle: ?*MH, slot: usize, out: ?*T) callconv(.c) c_int {
                return MH.getVerified(handle, slot, out);
            }
        };
        @export(
            &MutGetVerifiedWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_get_verified", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutUpdateWrapper = struct {
            fn call(handle: ?*MH, slot: usize, value: ?*const T) callconv(.c) c_int {
                return MH.update(handle, slot, value);
            }
        };
        @export(
            &MutUpdateWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_update", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutDeleteWrapper = struct {
            fn call(handle: ?*MH, slot: usize) callconv(.c) c_int {
                return MH.del(handle, slot);
            }
        };
        @export(
            &MutDeleteWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_delete", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutCompactWrapper = struct {
            fn call(handle: ?*MH) callconv(.c) void {
                MH.compact(handle);
            }
        };
        @export(
            &MutCompactWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_compact", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutReserveWrapper = struct {
            fn call(handle: ?*MH, additional: usize) callconv(.c) c_int {
                return MH.reserve(handle, additional);
            }
        };
        @export(
            &MutReserveWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_reserve", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutLenWrapper = struct {
            fn call(handle: ?*const MH) callconv(.c) usize {
                return MH.lenOf(handle);
            }
        };
        @export(
            &MutLenWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_len", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutLiveWrapper = struct {
            fn call(handle: ?*const MH) callconv(.c) usize {
                return MH.liveOf(handle);
            }
        };
        @export(
            &MutLiveWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_live", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutGenerationWrapper = struct {
            fn call(handle: ?*const MH) callconv(.c) u64 {
                return MH.generationOf(handle);
            }
        };
        @export(
            &MutGenerationWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_generation", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutFlushWrapper = struct {
            fn call(handle: ?*MH, out_len: ?*usize) callconv(.c) ?[*]u8 {
                return MH.flush(handle, out_len);
            }
        };
        @export(
            &MutFlushWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_flush", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutIterStartWrapper = struct {
            fn call(handle: ?*MH) callconv(.c) c_int {
                return MH.iterStart(handle);
            }
        };
        @export(
            &MutIterStartWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_iter_start", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutIterNextWrapper = struct {
            fn call(handle: ?*MH) callconv(.c) ?*const T {
                return MH.iterNext(handle);
            }
        };
        @export(
            &MutIterNextWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_iter_next", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );

        const MutIterResetWrapper = struct {
            fn call(handle: ?*MH) callconv(.c) void {
                MH.iterReset(handle);
            }
        };
        @export(
            &MutIterResetWrapper.call,
            .{
                .name = std.fmt.comptimePrint("{s}_mut_iter_reset", .{prefix}),
                .linkage = .strong,
                .visibility = .default,
            },
        );
    }
}

/// Generate the list of exported symbol names for a registry.
/// Use this when configuring export_symbol_names on your library module in build.zig.
pub fn getExportNames(comptime registry: []const SchemaDescriptor) []const []const u8 {
    // 42 functions per schema + 4 global functions
    const funcs_per_schema = 42;
    comptime var names: [registry.len * funcs_per_schema + 4][]const u8 = undefined;

    // Global functions
    names[0] = "zdl_last_error";
    names[1] = "zdl_error_message";
    names[2] = "zdl_alloc";
    names[3] = "zdl_free";

    inline for (registry, 0..) |entry, i| {
        const base = i * funcs_per_schema + 4;
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
        names[base + 23] = std.fmt.comptimePrint("{s}_serialize_into", .{entry.c_prefix});
        names[base + 24] = std.fmt.comptimePrint("{s}_serialized_size", .{entry.c_prefix});
        names[base + 25] = std.fmt.comptimePrint("{s}_mut_new", .{entry.c_prefix});
        names[base + 26] = std.fmt.comptimePrint("{s}_mut_load", .{entry.c_prefix});
        names[base + 27] = std.fmt.comptimePrint("{s}_mut_free", .{entry.c_prefix});
        names[base + 28] = std.fmt.comptimePrint("{s}_mut_append", .{entry.c_prefix});
        names[base + 29] = std.fmt.comptimePrint("{s}_mut_get", .{entry.c_prefix});
        names[base + 30] = std.fmt.comptimePrint("{s}_mut_get_verified", .{entry.c_prefix});
        names[base + 31] = std.fmt.comptimePrint("{s}_mut_update", .{entry.c_prefix});
        names[base + 32] = std.fmt.comptimePrint("{s}_mut_delete", .{entry.c_prefix});
        names[base + 33] = std.fmt.comptimePrint("{s}_mut_compact", .{entry.c_prefix});
        names[base + 34] = std.fmt.comptimePrint("{s}_mut_reserve", .{entry.c_prefix});
        names[base + 35] = std.fmt.comptimePrint("{s}_mut_len", .{entry.c_prefix});
        names[base + 36] = std.fmt.comptimePrint("{s}_mut_live", .{entry.c_prefix});
        names[base + 37] = std.fmt.comptimePrint("{s}_mut_generation", .{entry.c_prefix});
        names[base + 38] = std.fmt.comptimePrint("{s}_mut_flush", .{entry.c_prefix});
        names[base + 39] = std.fmt.comptimePrint("{s}_mut_iter_start", .{entry.c_prefix});
        names[base + 40] = std.fmt.comptimePrint("{s}_mut_iter_next", .{entry.c_prefix});
        names[base + 41] = std.fmt.comptimePrint("{s}_mut_iter_reset", .{entry.c_prefix});
    }
    const final = names;
    return &final;
}
