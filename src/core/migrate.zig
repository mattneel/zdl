const std = @import("std");

pub fn migrate(
    comptime FromT: type,
    comptime ToT: type,
    from_value: FromT,
) ToT {
    const from_version = comptime getVersion(FromT);
    const to_version = comptime getVersion(ToT);

    if (from_version == to_version) {
        if (FromT != ToT) {
            @compileError("Migration requested between types with same version but different definitions");
        }
        return from_value;
    }

    if (from_version < to_version) {
        return callUpMigration(FromT, ToT, from_value);
    } else {
        return callDownMigration(FromT, ToT, from_value);
    }
}

fn getVersion(comptime T: type) u32 {
    if (@hasDecl(T, "zdl_config")) {
        const cfg = @field(T, "zdl_config");
        if (@hasField(@TypeOf(cfg), "version")) {
            return @as(u32, @field(cfg, "version"));
        }
    }
    return 0;
}

fn callUpMigration(comptime FromT: type, comptime ToT: type, value: FromT) ToT {
    const from_version = comptime getVersion(FromT);
    const field_name = std.fmt.comptimePrint("from_v{d}", .{from_version});

    if (!@hasDecl(ToT, "zdl_config")) {
        @compileError(@typeName(ToT) ++ " missing zdl_config for migration");
    }

    const cfg = @field(ToT, "zdl_config");
    if (!@hasField(@TypeOf(cfg), "migrations")) {
        @compileError(@typeName(ToT) ++ " missing migrations block");
    }

    const migrations = @field(cfg, "migrations");
    if (!@hasField(@TypeOf(migrations), field_name)) {
        @compileError(@typeName(ToT) ++ " missing migration entry " ++ field_name);
    }

    const entry = @field(migrations, field_name);
    if (!@hasDecl(entry, "up")) {
        @compileError(@typeName(ToT) ++ " migration " ++ field_name ++ " missing 'up' function");
    }

    const up_fn = entry.up;
    const up_info = @typeInfo(@TypeOf(up_fn));
    if (up_info != .@"fn") {
        @compileError("Migration up must be a function");
    }
    if (up_info.@"fn".params.len != 1) {
        @compileError("Migration up must take exactly one argument");
    }
    if (up_info.@"fn".params[0].type.? != FromT) {
        @compileError("Migration up parameter type mismatch");
    }
    if (up_info.@"fn".return_type.? != ToT) {
        @compileError("Migration up return type mismatch");
    }

    return up_fn(value);
}

fn callDownMigration(comptime FromT: type, comptime ToT: type, value: FromT) ToT {
    const to_version = comptime getVersion(ToT);
    const field_name = std.fmt.comptimePrint("from_v{d}", .{to_version});

    if (!@hasDecl(FromT, "zdl_config")) {
        @compileError(@typeName(FromT) ++ " missing zdl_config for migration");
    }

    const cfg = @field(FromT, "zdl_config");
    if (!@hasField(@TypeOf(cfg), "migrations")) {
        @compileError(@typeName(FromT) ++ " missing migrations block");
    }

    const migrations = @field(cfg, "migrations");
    if (!@hasField(@TypeOf(migrations), field_name)) {
        @compileError(@typeName(FromT) ++ " missing migration entry " ++ field_name);
    }

    const entry = @field(migrations, field_name);
    if (!@hasDecl(entry, "down")) {
        @compileError(@typeName(FromT) ++ " migration " ++ field_name ++ " missing 'down' function");
    }

    const down_fn = entry.down;
    const down_info = @typeInfo(@TypeOf(down_fn));
    if (down_info != .@"fn") {
        @compileError("Migration down must be a function");
    }
    if (down_info.@"fn".params.len != 1) {
        @compileError("Migration down must take exactly one argument");
    }
    if (down_info.@"fn".params[0].type.? != FromT) {
        @compileError("Migration down parameter type mismatch");
    }
    if (down_info.@"fn".return_type.? != ToT) {
        @compileError("Migration down return type mismatch");
    }

    return down_fn(value);
}
