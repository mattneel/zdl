test {
    _ = @import("core/schema_test.zig");
    _ = @import("core/format_test.zig");
    _ = @import("core/serialize_test.zig");
    _ = @import("core/deserialize_test.zig");
    _ = @import("core/roundtrip_test.zig");
    _ = @import("core/migration_test.zig");
    _ = @import("core/integration_test.zig");
}
