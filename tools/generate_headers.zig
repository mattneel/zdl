const std = @import("std");
const zdl = @import("zdl");
const c_header = zdl.codegen.c_header;
const c_common = zdl.codegen.c_common;
const schemas = zdl.interop.schemas;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("usage: gen_headers <schemas.zig> <output_dir>\n", .{});
        return error.InvalidArgs;
    }

    const output_dir_path = args[2];
    var dir = try std.fs.cwd().makeOpenPath(output_dir_path, .{});
    defer dir.close();

    // Generate the common zdl.h header first
    {
        var file = try dir.createFile("zdl.h", .{ .truncate = true });
        defer file.close();

        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);

        try c_common.generateCommonHeader(list.writer(allocator));
        try file.writeAll(list.items);

        std.debug.print("generated zdl.h (common types)\n", .{});
    }

    // Generate per-schema headers
    inline for (schemas.registry) |entry| {
        const file_name = try std.fmt.allocPrint(allocator, "{s}.h", .{entry.c_prefix});
        defer allocator.free(file_name);

        var file = try dir.createFile(file_name, .{ .truncate = true });
        defer file.close();

        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);

        try c_header.generateHeader(entry.Type, list.writer(allocator));
        try file.writeAll(list.items);

        const type_name = c_header.simplifyTypeName(@typeName(entry.Type));
        std.debug.print("generated {s} ({s})\n", .{ file_name, type_name });
    }
}
