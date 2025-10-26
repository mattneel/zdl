const std = @import("std");
const zdl = @import("zdl");
const schema = zdl.schema;

const checkSchema = schema.checkSchema;
const SchemaError = schema.SchemaError;
const max_array_len = schema.max_array_len;

test "checkSchema allows primitive fields and arrays within limits" {
    const Valid = struct {
        id: u64,
        temperature: f32,
        active: bool,
        samples: [4]u16,
    };

    try checkSchema(Valid);
}

test "checkSchema rejects pointer fields" {
    const Bad = struct {
        ptr: *u8,
    };

    try std.testing.expectError(SchemaError.PointerNotAllowed, checkSchema(Bad));
}

test "checkSchema rejects slices" {
    const Bad = struct {
        data: []const u8,
    };

    try std.testing.expectError(SchemaError.SliceNotAllowed, checkSchema(Bad));
}

test "checkSchema rejects optionals" {
    const Bad = struct {
        maybe_value: ?u32,
    };

    try std.testing.expectError(SchemaError.OptionalNotAllowed, checkSchema(Bad));
}

test "checkSchema rejects error unions" {
    const Bad = struct {
        value: error{Oops}!u8,
    };

    try std.testing.expectError(SchemaError.ErrorUnionNotAllowed, checkSchema(Bad));
}

test "checkSchema enforces array length limit" {
    const Bad = struct {
        data: [max_array_len + 1]u8,
    };

    try std.testing.expectError(SchemaError.ArrayTooLarge, checkSchema(Bad));
}

test "checkSchema enforces nesting depth limit" {
    const Level9 = struct { value: u8 };
    const Level8 = struct { inner: Level9 };
    const Level7 = struct { inner: Level8 };
    const Level6 = struct { inner: Level7 };
    const Level5 = struct { inner: Level6 };
    const Level4 = struct { inner: Level5 };
    const Level3 = struct { inner: Level4 };
    const Level2 = struct { inner: Level3 };
    const Level1 = struct { inner: Level2 };
    const Root = struct { inner: Level1 };

    try std.testing.expectError(SchemaError.NestingTooDeep, checkSchema(Root));
}

test "checkSchema allows nesting at depth limit" {
    const Level8 = struct { value: u8 };
    const Level7 = struct { inner: Level8 };
    const Level6 = struct { inner: Level7 };
    const Level5 = struct { inner: Level6 };
    const Level4 = struct { inner: Level5 };
    const Level3 = struct { inner: Level4 };
    const Level2 = struct { inner: Level3 };
    const Level1 = struct { inner: Level2 };
    const Root = struct { inner: Level1 };

    try checkSchema(Root);
}

test "checkSchema rejects usize" {
    const Bad = struct {
        value: usize,
    };

    try std.testing.expectError(SchemaError.UsizeNotAllowed, checkSchema(Bad));
}
