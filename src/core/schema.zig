pub const max_array_len: usize = 65_536;
pub const max_nesting_depth: usize = 8;

pub const SchemaError = error{
    NotAStruct,
    PointerNotAllowed,
    SliceNotAllowed,
    OptionalNotAllowed,
    ErrorUnionNotAllowed,
    UsizeNotAllowed,
    ArrayTooLarge,
    NestingTooDeep,
    UnsupportedType,
};

pub fn checkSchema(comptime T: type) SchemaError!void {
    switch (@typeInfo(T)) {
        .@"struct" => {},
        else => return SchemaError.NotAStruct,
    }
    try validateStruct(T, 0);
}

pub fn ensure(comptime T: type) void {
    checkSchema(T) catch |err| {
        @compileError("schema validation failed: " ++ @errorName(err));
    };
}

fn validateStruct(comptime T: type, depth: usize) SchemaError!void {
    if (depth > max_nesting_depth) {
        return SchemaError.NestingTooDeep;
    }

    switch (@typeInfo(T)) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                return SchemaError.UnsupportedType;
            }

            inline for (struct_info.fields) |field| {
                if (field.is_comptime) continue;
                try validateType(field.type, depth + 1);
            }
        },
        else => return SchemaError.NotAStruct,
    }
}

fn validateType(comptime T: type, depth: usize) SchemaError!void {
    return switch (@typeInfo(T)) {
        .bool => {},
        .int => {
            if (T == usize or T == isize) {
                return SchemaError.UsizeNotAllowed;
            }
        },
        .float => {},
        .array => |array_info| {
            if (array_info.len > max_array_len) {
                return SchemaError.ArrayTooLarge;
            }
            try validateType(array_info.child, depth);
        },
        .@"struct" => try validateStruct(T, depth),
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => SchemaError.SliceNotAllowed,
            else => SchemaError.PointerNotAllowed,
        },
        .optional => SchemaError.OptionalNotAllowed,
        .error_union => SchemaError.ErrorUnionNotAllowed,
        .@"enum", .vector, .@"union", .@"opaque", .@"fn", .frame, .@"anyframe", .comptime_float, .comptime_int, .enum_literal, .null, .undefined, .error_set, .type, .noreturn, .void => SchemaError.UnsupportedType,
    };
}
