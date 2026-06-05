// Lifetime oracle for zdl.mutable.MutableContainer.
//
// Wire-format oracles (differential fuzzing, byte equality) verify that
// mutations write the right bytes. They are structurally blind to lifetime
// invariants: zdl's zero-copy query iterators and the C FFI
// (`*_query_iter_next` returns `*const T` across the ABI) hand out live
// pointers into container bytes, and MutableContainer makes the same shape
// of promise. This file checks the contract:
//
//   1. tombstone delete never moves bytes -> existing views stay readable
//      (grace semantics); subsequent traversals skip the record
//   2. in-place update never invalidates a view; the new value is visible
//      through it
//   3. relocation happens ONLY at named fences (compact, reserve): the fence
//      bumps the container generation, every older view traps with
//      error.StaleView, and compaction poisons freed slots (0xAA) in
//      safety-checked builds
//   4. the per-record CRC sidecar moves with records on compaction (never
//      recomputed) and stays consistent across all mutations
//
// The oracle itself is mutation-tested: "oracle has teeth" runs the same
// randomized schedule against a local BrokenContainer whose fences do not
// bump the generation, and asserts the oracle DETECTS the use-after-
// relocation it permits. An oracle that cannot fail its own mutation test
// proves nothing.
const std = @import("std");
const builtin = @import("builtin");
const zdl = @import("zdl");

const Rec = struct {
    id: u64,
    val: u64,

    pub const zdl_config = .{ .version = 1 };
};

const MC = zdl.mutable.MutableContainer(Rec);
const POISON = zdl.mutable.POISON;

fn makeInitial(comptime n: usize) [n]Rec {
    var out: [n]Rec = undefined;
    for (&out, 0..) |*rec, idx| {
        rec.* = .{ .id = idx, .val = idx * 100 };
    }
    return out;
}

test "stale view traps after compaction; fresh view works" {
    const initial = makeInitial(8);
    var mc = try MC.fromItems(std.testing.allocator, &initial, 16);
    defer mc.deinit();

    const v = try mc.view(5);
    try std.testing.expectEqual(@as(u64, 5), (try v.get()).id);

    try mc.delete(2);
    mc.compact();

    // pre-compaction view must trap, even though slot 5 still exists
    try std.testing.expectError(error.StaleView, v.get());

    // a fresh view sees the compacted (order-preserved) container
    const fresh = try mc.view(5);
    try std.testing.expectEqual(@as(u64, 6), (try fresh.get()).id); // slot 2 removed, ids shifted
}

test "tombstone delete preserves existing views and is skipped by traversal" {
    const initial = makeInitial(4);
    var mc = try MC.fromItems(std.testing.allocator, &initial, 8);
    defer mc.deinit();

    const doomed = try mc.view(1);
    try mc.delete(1);

    // grace semantics: the view still reads the stable bytes of the deleted record
    const rec = try doomed.get();
    try std.testing.expectEqual(@as(u64, 1), rec.id);
    try std.testing.expectEqual(@as(u64, 100), rec.val);

    // but a FRESH access refuses the tombstoned slot
    try std.testing.expectError(error.Deleted, mc.get(1));
    try std.testing.expectError(error.Deleted, mc.view(1));

    // traversal skips it
    var it = mc.iter();
    var seen: usize = 0;
    var ids: [4]u64 = undefined;
    while (try it.next()) |r| {
        ids[seen] = r.id;
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectEqualSlices(u64, &.{ 0, 2, 3 }, ids[0..3]);
}

test "in-place update is visible through live views without invalidation" {
    const initial = makeInitial(4);
    var mc = try MC.fromItems(std.testing.allocator, &initial, 8);
    defer mc.deinit();

    const v = try mc.view(3);
    try mc.update(3, .{ .id = 3, .val = 999 });

    // documented policy: no invalidation, new value visible through the view
    try std.testing.expectEqual(@as(u64, 999), (try v.get()).val);
}

test "iterator traps when a fence occurs mid-iteration" {
    const initial = makeInitial(8);
    var mc = try MC.fromItems(std.testing.allocator, &initial, 16);
    defer mc.deinit();

    var it = mc.iter();
    _ = try it.next();
    _ = try it.next();

    try mc.delete(6);
    mc.compact();

    try std.testing.expectError(error.StaleView, it.next());
}

test "compaction poisons freed slots in safety-checked builds" {
    if (builtin.mode != .Debug and builtin.mode != .ReleaseSafe) return error.SkipZigTest;
    const initial = makeInitial(8);
    var mc = try MC.fromItems(std.testing.allocator, &initial, 8);
    defer mc.deinit();

    try mc.delete(0);
    try mc.delete(7);
    mc.compact();

    try std.testing.expectEqual(@as(usize, 6), mc.len);
    // tests run in Debug, where poisoning is enabled
    const tail = std.mem.sliceAsBytes(mc.items[6..8]);
    for (tail) |byte| try std.testing.expectEqual(POISON, byte);
}

test "per-record CRC sidecar moves on compaction and stays consistent" {
    const initial = makeInitial(16);
    var mc = try MC.fromItems(std.testing.allocator, &initial, 32);
    defer mc.deinit();

    try mc.update(4, .{ .id = 4, .val = 4444 });
    try mc.delete(0);
    try mc.delete(9);
    try mc.verifyAll();
    mc.compact();
    try mc.verifyAll();
    _ = try mc.append(.{ .id = 100, .val = 1 });
    try mc.verifyAll();
}

// ---------------------------------------------------------------------------
// Randomized schedule, checked against a shadow model. Comparisons are
// RECORDED, not asserted, so the same harness can certify the real container
// (zero violations) and convict the broken one (teeth test). The harness
// derives every expectation from its own fence bookkeeping — a broken
// container cannot vouch for itself.
// ---------------------------------------------------------------------------

const Report = struct {
    accesses: usize = 0,
    traps: usize = 0, // accesses that correctly trapped as stale
    data_mismatches: usize = 0, // valid view returned wrong data
    unexpected_successes: usize = 0, // should have trapped, returned a record
    wrong_errors: usize = 0, // valid view errored
    crc_failures: usize = 0, // sidecar invariant broken
    fences: usize = 0, // compactions + reserves performed
    compactions: usize = 0,

    fn violations(self: Report) usize {
        return self.data_mismatches + self.unexpected_successes +
            self.wrong_errors + self.crc_failures;
    }
};

const ShadowRec = struct { id: u64, val: u64, tombstoned: bool };

fn runSchedule(comptime C: type, allocator: std.mem.Allocator, seed: u64) !Report {
    const CAPACITY = 256;
    const OPS = 4000;

    const TrackedView = struct {
        view: C.View,
        created_fences: usize,
        expected_id: u64,
        expected_val: u64,
        slot: usize,
    };

    const initial = makeInitial(64);
    var mc = try C.fromItems(allocator, &initial, CAPACITY);
    defer mc.deinit();

    var shadow: std.ArrayListUnmanaged(ShadowRec) = .empty;
    defer shadow.deinit(allocator);
    for (initial) |rec| {
        try shadow.append(allocator, .{ .id = rec.id, .val = rec.val, .tombstoned = false });
    }

    var tracked: std.ArrayListUnmanaged(TrackedView) = .empty;
    defer tracked.deinit(allocator);

    var report = Report{};
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var next_id: u64 = 1000;

    var op: usize = 0;
    while (op < OPS) : (op += 1) {
        const roll = random.uintLessThan(u32, 100);

        if (roll < 12) { // append
            const rec = Rec{ .id = next_id, .val = next_id *% 7 };
            _ = mc.append(rec) catch continue; // CapacityFull: skip
            next_id += 1;
            try shadow.append(allocator, .{ .id = rec.id, .val = rec.val, .tombstoned = false });
        } else if (roll < 42) { // update random live slot
            if (shadow.items.len == 0) continue;
            const slot = random.uintLessThan(usize, shadow.items.len);
            if (shadow.items[slot].tombstoned) continue;
            const new_val = random.int(u64);
            try mc.update(slot, .{ .id = shadow.items[slot].id, .val = new_val });
            shadow.items[slot].val = new_val;
            // visible-through policy: still-valid views of this slot now
            // expect the new value
            for (tracked.items) |*tv| {
                if (tv.slot == slot and tv.created_fences == report.fences) {
                    tv.expected_val = new_val;
                }
            }
        } else if (roll < 57) { // tombstone delete random live slot
            if (shadow.items.len == 0) continue;
            const slot = random.uintLessThan(usize, shadow.items.len);
            if (shadow.items[slot].tombstoned) continue;
            try mc.delete(slot);
            shadow.items[slot].tombstoned = true;
            // grace semantics: existing views unaffected, expectations unchanged
        } else if (roll < 77) { // create view over random live slot
            if (shadow.items.len == 0) continue;
            const slot = random.uintLessThan(usize, shadow.items.len);
            if (shadow.items[slot].tombstoned) continue;
            const v = mc.view(slot) catch continue;
            try tracked.append(allocator, .{
                .view = v,
                .created_fences = report.fences,
                .expected_id = shadow.items[slot].id,
                .expected_val = shadow.items[slot].val,
                .slot = slot,
            });
        } else if (roll < 95) { // access a random tracked view
            if (tracked.items.len == 0) continue;
            const tv = tracked.items[random.uintLessThan(usize, tracked.items.len)];
            report.accesses += 1;
            const must_trap = tv.created_fences != report.fences;
            if (tv.view.get()) |rec| {
                if (must_trap) {
                    report.unexpected_successes += 1;
                } else if (rec.id != tv.expected_id or rec.val != tv.expected_val) {
                    report.data_mismatches += 1;
                }
            } else |err| {
                if (must_trap and err == error.StaleView) {
                    report.traps += 1;
                } else {
                    report.wrong_errors += 1;
                }
            }
        } else if (roll < 98) { // compact (fence)
            mc.compact();
            report.fences += 1;
            report.compactions += 1;
            // shadow compacts identically: drop tombstoned, preserve order
            var w: usize = 0;
            var r: usize = 0;
            while (r < shadow.items.len) : (r += 1) {
                if (shadow.items[r].tombstoned) continue;
                shadow.items[w] = shadow.items[r];
                w += 1;
            }
            shadow.shrinkRetainingCapacity(w);
            mc.verifyAll() catch {
                report.crc_failures += 1;
            };
        } else { // reserve (fence; storage may move)
            mc.reserve(8) catch continue;
            report.fences += 1;
        }
    }

    return report;
}

test "randomized schedule: MutableContainer produces zero lifetime violations" {
    var seed: u64 = 1;
    while (seed <= 5) : (seed += 1) {
        const report = try runSchedule(MC, std.testing.allocator, seed);
        try std.testing.expectEqual(@as(usize, 0), report.violations());
        // the schedule must actually exercise the hazard, not vacuously pass
        try std.testing.expect(report.compactions > 0);
        try std.testing.expect(report.fences > report.compactions); // reserves too
        try std.testing.expect(report.traps > 0);
        try std.testing.expect(report.accesses > report.traps); // live accesses too
    }
}

// ---------------------------------------------------------------------------
// Teeth: a container whose fences do not bump the generation. Storage never
// moves (fixed capacity, reserve is a no-op) so stale accesses read stale or
// poisoned bytes — memory-safe, semantically wrong. The oracle must convict.
// ---------------------------------------------------------------------------

fn BrokenContainer(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []T,
        len: usize,
        live: usize,
        tomb: []u64,
        record_crcs: []u32,
        generation: u64,

        pub const View = struct {
            container: *const Self,
            slot: usize,
            generation: u64,

            pub fn get(self: View) error{StaleView}!*const T {
                if (self.generation != self.container.generation) return error.StaleView;
                // BUG under test: after an unfenced compaction this reads
                // relocated or poisoned bytes (slot is always < capacity, so
                // the access is memory-safe — just wrong).
                return &self.container.items[self.slot];
            }
        };

        pub fn fromItems(allocator: std.mem.Allocator, source: []const T, capacity: usize) !Self {
            const cap = @max(capacity, source.len);
            const items = try allocator.alloc(T, cap);
            errdefer allocator.free(items);
            @memcpy(items[0..source.len], source);
            const tomb = try allocator.alloc(u64, (cap + 63) / 64);
            errdefer allocator.free(tomb);
            @memset(tomb, 0);
            const crcs = try allocator.alloc(u32, cap);
            errdefer allocator.free(crcs);
            for (source, 0..) |*rec, slot| {
                crcs[slot] = zdl.crc.compute(std.mem.asBytes(rec));
            }
            return .{
                .allocator = allocator,
                .items = items,
                .len = source.len,
                .live = source.len,
                .tomb = tomb,
                .record_crcs = crcs,
                .generation = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.allocator.free(self.tomb);
            self.allocator.free(self.record_crcs);
        }

        fn isTombstoned(self: *const Self, slot: usize) bool {
            return (self.tomb[slot >> 6] >> @intCast(slot & 63)) & 1 == 1;
        }

        pub fn view(self: *const Self, slot: usize) error{ SlotOutOfRange, Deleted }!View {
            if (slot >= self.len) return error.SlotOutOfRange;
            if (self.isTombstoned(slot)) return error.Deleted;
            return .{ .container = self, .slot = slot, .generation = self.generation };
        }

        pub fn append(self: *Self, value: T) error{CapacityFull}!usize {
            if (self.len >= self.items.len) return error.CapacityFull;
            const slot = self.len;
            self.items[slot] = value;
            self.record_crcs[slot] = zdl.crc.compute(std.mem.asBytes(&self.items[slot]));
            self.len += 1;
            self.live += 1;
            return slot;
        }

        pub fn update(self: *Self, slot: usize, value: T) error{ SlotOutOfRange, Deleted }!void {
            if (slot >= self.len) return error.SlotOutOfRange;
            if (self.isTombstoned(slot)) return error.Deleted;
            self.items[slot] = value;
            self.record_crcs[slot] = zdl.crc.compute(std.mem.asBytes(&self.items[slot]));
        }

        pub fn delete(self: *Self, slot: usize) error{ SlotOutOfRange, AlreadyDeleted }!void {
            if (slot >= self.len) return error.SlotOutOfRange;
            if (self.isTombstoned(slot)) return error.AlreadyDeleted;
            self.tomb[slot >> 6] |= @as(u64, 1) << @intCast(slot & 63);
            self.live -= 1;
        }

        pub fn compact(self: *Self) void {
            var w: usize = 0;
            var r: usize = 0;
            while (r < self.len) : (r += 1) {
                if (self.isTombstoned(r)) continue;
                if (w != r) {
                    self.items[w] = self.items[r];
                    self.record_crcs[w] = self.record_crcs[r];
                }
                w += 1;
            }
            @memset(std.mem.sliceAsBytes(self.items[w..self.len]), POISON);
            @memset(self.tomb, 0);
            self.len = w;
            // BUG under test: no generation bump — outstanding views are
            // silently honored against relocated storage.
        }

        /// Correctly fences (bumps generation) but never reallocates —
        /// capacity is fixed so the broken model stays memory-safe. Keeping
        /// reserve correct makes the teeth conviction attributable to
        /// compact's missing bump alone.
        pub fn reserve(self: *Self, additional: usize) error{}!void {
            _ = additional;
            self.generation +%= 1;
        }

        pub fn verifyAll(self: *const Self) error{ChecksumMismatch}!void {
            var slot: usize = 0;
            while (slot < self.len) : (slot += 1) {
                if (self.isTombstoned(slot)) continue;
                if (zdl.crc.compute(std.mem.asBytes(&self.items[slot])) != self.record_crcs[slot]) {
                    return error.ChecksumMismatch;
                }
            }
        }
    };
}

test "oracle has teeth: convicts a container whose fences do not bump the generation" {
    var detected_runs: usize = 0;
    var seed: u64 = 1;
    while (seed <= 5) : (seed += 1) {
        const report = try runSchedule(BrokenContainer(Rec), std.testing.allocator, seed);
        if (report.violations() > 0) detected_runs += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), detected_runs);
}
