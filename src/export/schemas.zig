const c_api = @import("c_api.zig");

pub const SchemaDescriptor = c_api.SchemaDescriptor;

pub const types = struct {
    pub const FfiUser = struct {
        id: u64,
        score: f32,
        name: [32]u8,

        pub const zdl_config = .{
            .version = 1,
        };
    };
};

pub const registry = [_]SchemaDescriptor{
    .{ .Type = types.FfiUser, .c_prefix = "ffi_user" },
};
