const zdl = @import("root.zig");
const schemas = @import("export/schemas.zig");

comptime {
    zdl.interop.c_api.exportCApi(&schemas.registry);
}
