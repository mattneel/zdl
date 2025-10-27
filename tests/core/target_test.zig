const std = @import("std");
const Target = @import("zdl").Target;
const builtin = @import("builtin");

fn isBigEndian() bool {
    return builtin.target.cpu.arch.endian() == .big;
}

test "target alignment values" {
    try std.testing.expectEqual(@as(u32, 64), Target.cpu.alignment());
    try std.testing.expectEqual(@as(u32, 4096), Target.disk.alignment());
    try std.testing.expectEqual(@as(u32, 1), Target.network.alignment());
    try std.testing.expectEqual(@as(u32, 128), Target.cuda.alignment());
    try std.testing.expectEqual(@as(u32, 16), Target.metal.alignment());
}

test "network endian swap detection" {
    if (isBigEndian()) {
        try std.testing.expect(!Target.network.needsEndianSwap());
    } else {
        try std.testing.expect(Target.network.needsEndianSwap());
    }
}

test "network packed flag" {
    try std.testing.expect(Target.network.isPacked());
    try std.testing.expect(!Target.cpu.isPacked());
    try std.testing.expect(!Target.disk.isPacked());
}
