//! Mutable container: in-memory CRUD over the v1 array container format.
//!
//! The wire format is unchanged — `load` ingests a container produced by
//! `format.serializeArray` (validating the container CRC once) and `flush`
//! emits one (recomputing it). Between those boundaries, integrity moves to a
//! per-record CRC sidecar, which is what makes mutation affordable: updating
//! one record re-CRCs 1 record, not the whole container, and a point read can
//! be integrity-verified in O(record).
//!
//! Lifetime contract (pinned by tests/core/lifetime_oracle_test.zig):
//!
//! - Zero-copy views (`view`, `get`, `iter`) hand out pointers into container
//!   storage — the same shape the query iterators and the C FFI expose.
//! - `delete` is a tombstone: bytes never move, existing views keep reading
//!   stable bytes (grace semantics), traversals skip the record.
//! - `update` mutates in place: views stay valid and see the new value
//!   (visible-through policy).
//! - Relocation happens ONLY at named fences: `compact()` and `reserve()`.
//!   A fence bumps the container generation; any older view traps with
//!   `error.StaleView` on its next access. In safety-checked builds, slots
//!   freed by compaction are poisoned with 0xAA.
//! - `append` never relocates — it fails with `error.CapacityFull` rather
//!   than reallocating under live views; call `reserve` (a fence) first.
const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");
const schema = @import("schema.zig");
const Target = @import("target.zig").Target;
const crc32 = @import("crc.zig");

/// Byte written over slots freed by compaction in safety-checked builds.
pub const POISON: u8 = 0xAA;

const poison_enabled = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const LoadError = error{
    UnsupportedTarget,
    NotAnArrayContainer,
    SizeMismatch,
    ChecksumMismatch,
    VersionMismatch,
} || format.FormatError || std.mem.Allocator.Error;

pub const FlushError = error{DataTooLarge} || std.mem.Allocator.Error;

pub fn MutableContainer(comptime T: type) type {
    comptime schema.ensure(T);

    return struct {
        const Self = @This();
        const RECORD_SIZE: usize = @sizeOf(T);

        /// Whether storing a T by field assignment leaves bytes of its
        /// footprint unwritten (struct padding, oversized int/float storage).
        /// If so, record writes must zero the destination first: the compiler
        /// is free to construct `canonicalize`'s result in place (RVO), which
        /// silently skips its padding zeroing in optimized builds. Record
        /// bytes — and therefore CRCs and flushed wire bytes — must be a pure
        /// function of logical value.
        const needs_padding_zero = hasUndefinedBytes(T);

        pub const AccessError = error{ SlotOutOfRange, Deleted };
        pub const ViewError = error{StaleView};
        pub const AppendError = error{CapacityFull};
        pub const DeleteError = error{ SlotOutOfRange, AlreadyDeleted };
        pub const VerifiedReadError = AccessError || error{ChecksumMismatch};

        allocator: std.mem.Allocator,
        /// record storage; [0..len) initialized, items.len is capacity
        items: []T,
        /// slots in use, including tombstoned ones (compaction reclaims)
        len: usize,
        /// non-tombstoned record count
        live: usize,
        /// tombstone bitmap over [0..len)
        tomb: []u64,
        /// per-record CRC32 sidecar over [0..len)
        record_crcs: []u32,
        /// bumped at every relocation fence (compact, reserve); views created
        /// under an older generation trap with error.StaleView
        generation: u64,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!Self {
            const items = try allocator.alloc(T, capacity);
            errdefer allocator.free(items);
            const tomb = try allocator.alloc(u64, tombWords(capacity));
            errdefer allocator.free(tomb);
            @memset(tomb, 0);
            const crcs = try allocator.alloc(u32, capacity);
            errdefer allocator.free(crcs);

            return .{
                .allocator = allocator,
                .items = items,
                .len = 0,
                .live = 0,
                .tomb = tomb,
                .record_crcs = crcs,
                .generation = 0,
            };
        }

        pub fn fromItems(
            allocator: std.mem.Allocator,
            source: []const T,
            capacity: usize,
        ) std.mem.Allocator.Error!Self {
            var self = try init(allocator, @max(capacity, source.len));
            for (source) |value| {
                _ = self.append(value) catch unreachable; // capacity guaranteed
            }
            return self;
        }

        /// Ingest a v1 array container (as produced by `format.serializeArray`
        /// or `flush`). Validates the header and the whole-container CRC once,
        /// then builds the per-record sidecar.
        pub fn load(
            allocator: std.mem.Allocator,
            bytes: []const u8,
            extra_capacity: usize,
        ) LoadError!Self {
            const header_len = @as(usize, format.HEADER_SIZE);
            if (bytes.len < header_len + 8) {
                return error.NotAnArrayContainer;
            }
            const header = try format.validateHeader(bytes[0..header_len]);
            if (header.target != @intFromEnum(Target.cpu)) {
                return error.UnsupportedTarget;
            }
            // refuse version drift: flush() would silently re-stamp the
            // container with T's version; migration belongs to the migrate
            // module, not here
            if (header.version != format.schemaVersion(T)) {
                return error.VersionMismatch;
            }

            const count_u64 = try format.arrayCount(bytes);
            const count = std.math.cast(usize, count_u64) orelse return error.SizeMismatch;
            const expected_bytes = std.math.mul(u64, count_u64, RECORD_SIZE) catch return error.SizeMismatch;
            if (expected_bytes != header.length) {
                return error.SizeMismatch;
            }
            const items_len = std.math.cast(usize, expected_bytes) orelse return error.SizeMismatch;
            if (bytes.len != header_len + 8 + items_len) {
                return error.SizeMismatch;
            }

            const payload = bytes[header_len + 8 ..][0..items_len];
            if (crc32.compute(payload) != header.checksum) {
                return error.ChecksumMismatch;
            }

            var self = try init(allocator, count + extra_capacity);
            errdefer self.deinit();
            @memcpy(std.mem.sliceAsBytes(self.items[0..count]), payload);
            self.len = count;
            self.live = count;
            for (0..count) |slot| {
                self.record_crcs[slot] = crc32.compute(self.recordBytes(slot));
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.allocator.free(self.tomb);
            self.allocator.free(self.record_crcs);
        }

        /// Emit a v1 array container holding the live records in slot order.
        /// Tombstoned records are skipped; `self` is not mutated and no fence
        /// occurs. The whole-container CRC is recomputed here — this is the
        /// only place that cost is paid.
        pub fn flush(self: *const Self, allocator: std.mem.Allocator) FlushError![]u8 {
            const header_len = @as(usize, format.HEADER_SIZE);
            const items_bytes_u64 = std.math.mul(u64, @as(u64, self.live), RECORD_SIZE) catch
                return error.DataTooLarge;
            if (items_bytes_u64 > format.MAX_DATA_SIZE) {
                return error.DataTooLarge;
            }
            const items_bytes = std.math.cast(usize, items_bytes_u64) orelse return error.DataTooLarge;

            const buffer = try allocator.alloc(u8, header_len + 8 + items_bytes);
            errdefer allocator.free(buffer);

            std.mem.writeInt(u64, buffer[header_len..][0..8], @as(u64, self.live), .little);

            var offset = header_len + 8;
            var slot: usize = 0;
            while (slot < self.len) : (slot += 1) {
                if (self.isTombstoned(slot)) continue;
                @memcpy(buffer[offset..][0..RECORD_SIZE], self.recordBytes(slot));
                offset += RECORD_SIZE;
            }
            std.debug.assert(offset == buffer.len);

            const items_slice = buffer[header_len + 8 ..];
            const header = format.Header{
                .magic = format.MAGIC,
                .version = format.schemaVersion(T),
                .target = @intFromEnum(Target.cpu),
                .reserved = .{ 0, 0, 0 },
                .length = items_bytes_u64,
                .checksum = crc32.compute(items_slice),
            };
            format.writeHeader(header, buffer[0..header_len]);
            return buffer;
        }

        /// Borrowed zero-copy reference. Captures the generation at creation;
        /// access after any relocation fence traps. A view of a record that is
        /// later tombstoned keeps reading its stable bytes (grace semantics).
        pub const View = struct {
            container: *const Self,
            slot: usize,
            generation: u64,

            pub fn get(self: View) ViewError!*const T {
                if (self.generation != self.container.generation) return error.StaleView;
                // slots never disappear without a fence, so a generation-valid
                // view always points inside [0..len)
                std.debug.assert(self.slot < self.container.len);
                return &self.container.items[self.slot];
            }
        };

        pub fn view(self: *const Self, slot: usize) AccessError!View {
            if (slot >= self.len) return error.SlotOutOfRange;
            if (self.isTombstoned(slot)) return error.Deleted;
            return .{ .container = self, .slot = slot, .generation = self.generation };
        }

        /// Fresh zero-copy read. Refuses tombstoned slots (grace semantics
        /// apply only to views created before the delete).
        pub fn get(self: *const Self, slot: usize) AccessError!*const T {
            if (slot >= self.len) return error.SlotOutOfRange;
            if (self.isTombstoned(slot)) return error.Deleted;
            return &self.items[slot];
        }

        /// Integrity-checked point read: O(record), not O(container). Returns
        /// a copy so the verification still holds after later mutations.
        pub fn getVerified(self: *const Self, slot: usize) VerifiedReadError!T {
            if (slot >= self.len) return error.SlotOutOfRange;
            if (self.isTombstoned(slot)) return error.Deleted;
            if (crc32.compute(self.recordBytes(slot)) != self.record_crcs[slot]) {
                return error.ChecksumMismatch;
            }
            return self.items[slot];
        }

        /// Append into existing capacity. Never relocates: fails with
        /// CapacityFull instead of reallocating under live views.
        pub fn append(self: *Self, value: T) AppendError!usize {
            if (self.len >= self.items.len) return error.CapacityFull;
            const slot = self.len;
            self.storeRecord(slot, value);
            self.len += 1;
            self.live += 1;
            return slot;
        }

        /// In-place update. Views of this slot stay valid and observe the new
        /// value. Re-CRCs exactly one record.
        pub fn update(self: *Self, slot: usize, value: T) AccessError!void {
            if (slot >= self.len) return error.SlotOutOfRange;
            if (self.isTombstoned(slot)) return error.Deleted;
            self.storeRecord(slot, value);
        }

        /// Tombstone delete: no bytes move, no fence. Existing views keep
        /// reading the record's stable bytes; traversals skip it from now on.
        pub fn delete(self: *Self, slot: usize) DeleteError!void {
            if (slot >= self.len) return error.SlotOutOfRange;
            if (self.isTombstoned(slot)) return error.AlreadyDeleted;
            self.tomb[slot >> 6] |= @as(u64, 1) << @intCast(slot & 63);
            self.live -= 1;
        }

        /// Relocation fence: slide live records down (order preserved), move
        /// their sidecar CRCs (never recomputed), poison the freed tail in
        /// safety-checked builds, and bump the generation so every outstanding
        /// view traps. Always fences, even when nothing was tombstoned.
        pub fn compact(self: *Self) void {
            var w: usize = 0;
            var r: usize = 0;
            while (r < self.len) : (r += 1) {
                if (self.isTombstoned(r)) continue;
                if (w != r) {
                    // byte copy, not struct assignment: assignment is not
                    // guaranteed to carry padding bytes, which would desync
                    // the moved record from its moved CRC
                    @memcpy(
                        std.mem.asBytes(&self.items[w]),
                        std.mem.asBytes(&self.items[r]),
                    );
                    self.record_crcs[w] = self.record_crcs[r];
                }
                w += 1;
            }
            std.debug.assert(w == self.live);
            if (poison_enabled and w < self.len) {
                @memset(std.mem.sliceAsBytes(self.items[w..self.len]), POISON);
            }
            @memset(self.tomb, 0);
            self.len = w;
            self.generation +%= 1;
        }

        /// Relocation fence: grow capacity by at least `additional` slots.
        /// Storage may move, so the generation always bumps — callers must
        /// treat reserve like compact and reacquire views.
        ///
        /// Failure-atomic: all new buffers are allocated before anything is
        /// committed, so an OutOfMemory leaves the container (and its
        /// generation) exactly as it was.
        pub fn reserve(self: *Self, additional: usize) std.mem.Allocator.Error!void {
            const new_capacity = self.items.len + additional;
            const new_items = try self.allocator.alloc(T, new_capacity);
            errdefer self.allocator.free(new_items);
            const new_crcs = try self.allocator.alloc(u32, new_capacity);
            errdefer self.allocator.free(new_crcs);
            const new_tomb = try self.allocator.alloc(u64, tombWords(new_capacity));
            // commit point — nothing below can fail
            @memcpy(
                std.mem.sliceAsBytes(new_items[0..self.len]),
                std.mem.sliceAsBytes(self.items[0..self.len]),
            );
            @memcpy(new_crcs[0..self.len], self.record_crcs[0..self.len]);
            @memset(new_tomb, 0);
            @memcpy(new_tomb[0..self.tomb.len], self.tomb);
            self.allocator.free(self.items);
            self.allocator.free(self.record_crcs);
            self.allocator.free(self.tomb);
            self.items = new_items;
            self.record_crcs = new_crcs;
            self.tomb = new_tomb;
            self.generation +%= 1;
        }

        pub const Iterator = struct {
            container: *const Self,
            cursor: usize,
            generation: u64,

            pub fn next(self: *Iterator) ViewError!?*const T {
                if (self.generation != self.container.generation) return error.StaleView;
                while (self.cursor < self.container.len) {
                    const slot = self.cursor;
                    self.cursor += 1;
                    if (self.container.isTombstoned(slot)) continue;
                    return &self.container.items[slot];
                }
                return null;
            }
        };

        /// Zero-copy traversal of live records in slot order. Generation-
        /// stamped: traps with StaleView if a fence occurs mid-iteration.
        /// Unfenced mutations interleave: a record tombstoned before the
        /// cursor reaches it is skipped, and a record appended during
        /// iteration is visited.
        pub fn iter(self: *const Self) Iterator {
            return .{ .container = self, .cursor = 0, .generation = self.generation };
        }

        /// Sidecar invariant check: every live record's stored CRC matches a
        /// fresh computation over its bytes.
        pub fn verifyAll(self: *const Self) error{ChecksumMismatch}!void {
            var slot: usize = 0;
            while (slot < self.len) : (slot += 1) {
                if (self.isTombstoned(slot)) continue;
                if (crc32.compute(self.recordBytes(slot)) != self.record_crcs[slot]) {
                    return error.ChecksumMismatch;
                }
            }
        }

        pub fn isTombstoned(self: *const Self, slot: usize) bool {
            return (self.tomb[slot >> 6] >> @intCast(slot & 63)) & 1 == 1;
        }

        /// Canonical record store: deterministic bytes (zeroed padding)
        /// regardless of optimizer behavior, sidecar CRC kept in sync.
        fn storeRecord(self: *Self, slot: usize, value: T) void {
            if (comptime needs_padding_zero) {
                @memset(std.mem.asBytes(&self.items[slot]), 0);
            }
            self.items[slot] = format.canonicalize(T, value);
            self.record_crcs[slot] = crc32.compute(self.recordBytes(slot));
        }

        fn recordBytes(self: *const Self, slot: usize) []const u8 {
            return std.mem.asBytes(&self.items[slot]);
        }

        fn tombWords(capacity: usize) usize {
            return (capacity + 63) / 64;
        }
    };
}

/// True when F's in-memory footprint contains bytes a plain field-wise store
/// does not write: struct padding (including nested) and int/float types
/// whose storage exceeds their bit width (u24 in 4 bytes, f80 in 16).
fn hasUndefinedBytes(comptime F: type) bool {
    return switch (@typeInfo(F)) {
        .bool => false,
        .int => |info| @sizeOf(F) * 8 != info.bits,
        .float => |info| @sizeOf(F) * 8 != info.bits,
        .array => |info| hasUndefinedBytes(info.child),
        .@"struct" => |struct_info| blk: {
            var covered: usize = 0;
            for (struct_info.fields) |field| {
                if (field.is_comptime) continue;
                if (hasUndefinedBytes(field.type)) break :blk true;
                covered += @sizeOf(field.type);
            }
            // fields never overlap, so full coverage means no padding
            break :blk covered != @sizeOf(F);
        },
        else => true, // conservative: zero anything unrecognized
    };
}
