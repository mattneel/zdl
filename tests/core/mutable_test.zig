const std = @import("std");
const zdl = @import("zdl");

const Sample = struct {
    id: u64,
    score: f32,

    pub const zdl_config = .{ .version = 1 };
};

const MC = zdl.mutable.MutableContainer(Sample);

fn makeSamples(comptime n: usize) [n]Sample {
    var out: [n]Sample = undefined;
    for (&out, 0..) |*item, idx| {
        out[idx] = .{ .id = idx, .score = @floatFromInt(idx * 10) };
        _ = item;
    }
    return out;
}

test "append, get, update, delete, iter basics" {
    const gpa = std.testing.allocator;
    var mc = try MC.init(gpa, 8);
    defer mc.deinit();

    const s0 = try mc.append(.{ .id = 10, .score = 1.0 });
    const s1 = try mc.append(.{ .id = 11, .score = 2.0 });
    const s2 = try mc.append(.{ .id = 12, .score = 3.0 });
    try std.testing.expectEqual(@as(usize, 3), mc.live);

    try std.testing.expectEqual(@as(u64, 11), (try mc.get(s1)).id);

    try mc.update(s1, .{ .id = 11, .score = 99.0 });
    try std.testing.expectEqual(@as(f32, 99.0), (try mc.get(s1)).score);

    try mc.delete(s0);
    try std.testing.expectEqual(@as(usize, 2), mc.live);
    try std.testing.expectError(error.Deleted, mc.get(s0));
    try std.testing.expectError(error.AlreadyDeleted, mc.delete(s0));

    var it = mc.iter();
    var ids: [2]u64 = undefined;
    var n: usize = 0;
    while (try it.next()) |item| {
        ids[n] = item.id;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u64, &.{ 11, 12 }, &ids);
    _ = s2;
}

test "append fails with CapacityFull instead of relocating; reserve is a fence" {
    const gpa = std.testing.allocator;
    var mc = try MC.init(gpa, 2);
    defer mc.deinit();

    _ = try mc.append(.{ .id = 1, .score = 0 });
    _ = try mc.append(.{ .id = 2, .score = 0 });
    try std.testing.expectError(error.CapacityFull, mc.append(.{ .id = 3, .score = 0 }));

    const v = try mc.view(0);
    const gen_before = mc.generation;
    try mc.reserve(8);
    try std.testing.expect(mc.generation != gen_before);
    try std.testing.expectError(error.StaleView, v.get()); // storage may have moved

    _ = try mc.append(.{ .id = 3, .score = 0 }); // capacity now available
    try std.testing.expectEqual(@as(usize, 3), mc.live);
    try mc.verifyAll();
}

test "getVerified checks the record CRC and detects corruption" {
    const gpa = std.testing.allocator;
    var mc = try MC.init(gpa, 4);
    defer mc.deinit();

    const slot = try mc.append(.{ .id = 7, .score = 1.5 });
    const rec = try mc.getVerified(slot);
    try std.testing.expectEqual(@as(u64, 7), rec.id);

    // corrupt the stored bytes behind the sidecar's back
    mc.items[slot].id = 8;
    try std.testing.expectError(error.ChecksumMismatch, mc.getVerified(slot));
    try std.testing.expectError(error.ChecksumMismatch, mc.verifyAll());
}

test "load -> flush of an untouched container is byte-identical" {
    const gpa = std.testing.allocator;
    const samples = makeSamples(32);

    const wire = try zdl.format.serializeArray(Sample, &samples, .cpu, gpa);
    defer gpa.free(@constCast(wire));

    var mc = try MC.load(gpa, wire, 0);
    defer mc.deinit();
    try std.testing.expectEqual(@as(usize, 32), mc.live);
    try mc.verifyAll();

    const out = try mc.flush(gpa);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, wire, out);
}

test "load rejects corrupted containers" {
    const gpa = std.testing.allocator;
    const samples = makeSamples(4);
    const wire = try zdl.format.serializeArray(Sample, &samples, .cpu, gpa);
    defer gpa.free(@constCast(wire));

    const corrupted = try gpa.dupe(u8, wire);
    defer gpa.free(corrupted);
    corrupted[zdl.format.HEADER_SIZE + 8 + 3] ^= 0xFF; // flip a payload bit

    try std.testing.expectError(error.ChecksumMismatch, MC.load(gpa, corrupted, 0));
}

test "mutate then flush round-trips through query and load" {
    const gpa = std.testing.allocator;
    const samples = makeSamples(8);
    const wire = try zdl.format.serializeArray(Sample, &samples, .cpu, gpa);
    defer gpa.free(@constCast(wire));

    var mc = try MC.load(gpa, wire, 4);
    defer mc.deinit();

    try mc.delete(2);
    try mc.update(5, .{ .id = 5, .score = 555.0 });
    _ = try mc.append(.{ .id = 100, .score = 1.0 });
    try mc.verifyAll();

    const out = try mc.flush(gpa);
    defer gpa.free(out);

    // flushed wire is a valid v1 container: query can read it
    var qb = zdl.query.query(Sample, out, gpa);
    defer qb.deinit();
    var it = try qb.iter();
    var ids: [8]u64 = undefined;
    var n: usize = 0;
    while (it.next()) |item| {
        ids[n] = item.id;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), n); // 8 - 1 deleted + 1 appended
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 3, 4, 5, 6, 7, 100 }, ids[0..n]);

    // and load() accepts it with a consistent sidecar
    var reloaded = try MC.load(gpa, out, 0);
    defer reloaded.deinit();
    try reloaded.verifyAll();
    try std.testing.expectEqual(@as(f32, 555.0), (try reloaded.get(4)).score);
}

test "flush bytes are a pure function of logical content (padded type)" {
    // Regression: with RVO, `items[slot] = canonicalize(...)` can construct
    // the result in place and skip padding zeroing, leaving stale bytes in
    // the record (self-consistent CRC, nondeterministic wire). Run with
    // -Doptimize=ReleaseFast for full effect; Debug passes trivially.
    const gpa = std.testing.allocator;
    const Padded = struct {
        flag: u8,
        id: u64, // 7 bytes of padding in this struct
        pub const zdl_config = .{ .version = 1 };
    };
    const PMC = zdl.mutable.MutableContainer(Padded);
    const final = [_]Padded{
        .{ .flag = 1, .id = 10 },
        .{ .flag = 2, .id = 20 },
        .{ .flag = 3, .id = 30 },
        .{ .flag = 4, .id = 40 },
    };

    // history A: records stored once, into fresh slots
    var a = try PMC.fromItems(gpa, &final, 8);
    defer a.deinit();

    // history B: same logical end state, but every slot previously held
    // different record bytes (dirty backing store for the padding)
    var b = try PMC.init(gpa, 8);
    defer b.deinit();
    var fill: usize = 0;
    while (fill < 8) : (fill += 1) {
        _ = try b.append(.{ .flag = 0xFF, .id = 0xFFFF_FFFF_FFFF_FFFF });
    }
    var slot: usize = 0;
    while (slot < b.len) : (slot += 1) try b.delete(slot);
    b.compact();
    for (final) |rec| _ = try b.append(rec);
    try b.update(0, final[0]); // cover the update path too

    const wire_a = try a.flush(gpa);
    defer gpa.free(wire_a);
    const wire_b = try b.flush(gpa);
    defer gpa.free(wire_b);
    try std.testing.expectEqualSlices(u8, wire_a, wire_b);

    // and both match the immutable wire path for the same records
    const reference = try zdl.format.serializeArray(Padded, &final, .cpu, gpa);
    defer gpa.free(@constCast(reference));
    try std.testing.expectEqualSlices(u8, wire_a, reference);
}

test "load rejects schema version drift" {
    const gpa = std.testing.allocator;
    const V1 = struct {
        id: u64,
        pub const zdl_config = .{ .version = 1 };
    };
    const V2 = struct {
        id: u64,
        pub const zdl_config = .{ .version = 2 };
    };
    const wire = try zdl.format.serializeArray(V1, &.{.{ .id = 1 }}, .cpu, gpa);
    defer gpa.free(@constCast(wire));

    try std.testing.expectError(
        error.VersionMismatch,
        zdl.mutable.MutableContainer(V2).load(gpa, wire, 0),
    );
}

test "reserve is failure-atomic under OOM" {
    // init performs 3 allocations (items, tomb, record_crcs); reserve
    // performs 3 more (new items, new crcs, new tomb). Fail the middle
    // reserve allocation and require the container to be untouched.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 4 });
    const alloc = failing.allocator();

    var mc = try zdl.mutable.MutableContainer(Sample).init(alloc, 4);
    defer mc.deinit();
    _ = try mc.append(.{ .id = 1, .score = 1.0 });
    _ = try mc.append(.{ .id = 2, .score = 2.0 });
    const gen_before = mc.generation;

    try std.testing.expectError(error.OutOfMemory, mc.reserve(64));

    // no fence happened, no state desynced: views stay valid, sidecar
    // consistent, container fully usable within its old capacity
    try std.testing.expectEqual(gen_before, mc.generation);
    try mc.verifyAll();
    _ = try mc.append(.{ .id = 3, .score = 3.0 });
    try std.testing.expectEqual(@as(usize, 3), mc.live);
    try mc.verifyAll();
}

test "iterator without a fence: skips mid-iteration tombstones, sees appends" {
    const gpa = std.testing.allocator;
    var mc = try MC.fromItems(gpa, &.{
        .{ .id = 0, .score = 0 },
        .{ .id = 1, .score = 0 },
        .{ .id = 2, .score = 0 },
        .{ .id = 3, .score = 0 },
    }, 8);
    defer mc.deinit();

    var it = mc.iter();
    try std.testing.expectEqual(@as(u64, 0), (try it.next()).?.id);

    // unfenced mutations interleave with iteration: a record tombstoned
    // before the cursor reaches it is skipped...
    try mc.delete(2);
    // ...and a record appended during iteration is visited
    _ = try mc.append(.{ .id = 100, .score = 0 });

    try std.testing.expectEqual(@as(u64, 1), (try it.next()).?.id);
    try std.testing.expectEqual(@as(u64, 3), (try it.next()).?.id);
    try std.testing.expectEqual(@as(u64, 100), (try it.next()).?.id);
    try std.testing.expectEqual(@as(?*const Sample, null), try it.next());
}

test "compaction preserves order, moves CRCs, and flushes identically" {
    const gpa = std.testing.allocator;
    const samples = makeSamples(16);
    var mc = try MC.fromItems(gpa, &samples, 16);
    defer mc.deinit();

    try mc.delete(0);
    try mc.delete(7);
    try mc.delete(15);

    // flush before compaction and after must produce identical wire bytes:
    // compaction changes layout, never logical content
    const before = try mc.flush(gpa);
    defer gpa.free(before);

    mc.compact();
    try std.testing.expectEqual(@as(usize, 13), mc.len);
    try mc.verifyAll();

    const after = try mc.flush(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}
