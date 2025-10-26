const std = @import("std");

const polynomial: u32 = 0xEDB88320;

fn buildTable() [256]u32 {
    @setEvalBranchQuota(4096);
    var result: [256]u32 = undefined;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var crc = i;
        var bit: u32 = 0;
        while (bit < 8) : (bit += 1) {
            if ((crc & 1) == 1) {
                crc = polynomial ^ (crc >> 1);
            } else {
                crc >>= 1;
            }
        }
        result[i] = crc;
    }
    return result;
}

const table = buildTable();

pub fn compute(bytes: []const u8) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    for (bytes) |byte| {
        const idx = (crc ^ byte) & 0xFF;
        crc = (crc >> 8) ^ table[idx];
    }
    return ~crc;
}

test "crc matches std implementation" {
    const sample = [_]u8{ 0xef, 0xbe, 0xad, 0xde, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x3f, 0x01, 0x00, 0x00, 0x00 };
    const expected = std.hash.crc.Crc32.hash(&sample);
    try std.testing.expectEqual(expected, compute(&sample));
}
