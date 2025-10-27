const std = @import("std");

pub const schema = @import("core/schema.zig");
pub const format = @import("core/format.zig");
pub const crc = @import("core/crc.zig");
pub const Target = @import("core/target.zig").Target;
pub const serialize = @import("core/serialize.zig");
pub const deserialize = @import("core/deserialize.zig");
pub const migrate = @import("core/migrate.zig");
pub const changeset = @import("core/changeset.zig");
pub const validators = @import("core/validators.zig");
pub const query = @import("core/query.zig");
pub const layout = @import("core/layout.zig");
const c_header_mod = @import("codegen/c_header.zig");
const c_api_mod = @import("export/c_api.zig");
const schemas_mod = @import("export/schemas.zig");

comptime {
    _ = c_api_mod;
}

pub const codegen = struct {
    pub const c_header = c_header_mod;
};
pub const interop = struct {
    pub const c_api = c_api_mod;
    pub const schemas = schemas_mod;
};

pub fn bufferedPrint() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}
