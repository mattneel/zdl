const builtin = @import("builtin");

pub const Target = enum(u8) {
    cpu = 0,
    disk = 1,
    network = 2,
    cuda = 3,
    metal = 4,

    pub fn alignment(self: Target) u32 {
        return switch (self) {
            .cpu => 64,
            .disk => 4096,
            .network => 1,
            .cuda => 128,
            .metal => 16,
        };
    }

    pub fn needsEndianSwap(self: Target) bool {
        return switch (self) {
            .network => !isNativeBigEndian(),
            else => false,
        };
    }

    pub fn isPacked(self: Target) bool {
        return switch (self) {
            .network => true,
            else => false,
        };
    }
};

fn isNativeBigEndian() bool {
    return builtin.target.cpu.arch.endian() == .big;
}
