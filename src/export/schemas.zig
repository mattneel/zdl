pub const SchemaDescriptor = struct {
    /// Type to expose through the C API.
    Type: type,
    /// Lowercase snake prefix used for function names and header files.
    c_prefix: []const u8,
};

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
