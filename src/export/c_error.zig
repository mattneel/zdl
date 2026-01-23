const std = @import("std");

/// Error codes for the C API. These map to zdl_error_t in the C header.
pub const Error = enum(c_int) {
    ok = 0,
    null_param = 1,
    invalid_field = 2,
    type_mismatch = 3,
    buffer_corrupt = 4,
    out_of_memory = 5,
    limit_exceeded = 6,
    limit_required = 7,
    too_many_filters = 8,
    iterator_not_started = 9,
    unsupported_type = 10,
};

/// Thread-local storage for the last error that occurred.
threadlocal var last_error: Error = .ok;

/// Set the thread-local error state.
pub fn setError(err: Error) void {
    last_error = err;
}

/// Get the thread-local error state.
pub fn getError() Error {
    return last_error;
}

/// Clear the thread-local error state.
pub fn clearError() void {
    last_error = .ok;
}

/// Get a human-readable error message for the given error code.
pub fn errorMessage(err: Error) [*:0]const u8 {
    return switch (err) {
        .ok => "Success",
        .null_param => "Null parameter provided",
        .invalid_field => "Invalid field name",
        .type_mismatch => "Type mismatch in filter value",
        .buffer_corrupt => "Buffer is corrupt or invalid",
        .out_of_memory => "Out of memory",
        .limit_exceeded => "Result limit exceeded",
        .limit_required => "Limit required for collect operation",
        .too_many_filters => "Too many filters applied",
        .iterator_not_started => "Iterator not started",
        .unsupported_type => "Unsupported field type for filtering",
    };
}

/// Convert a Zig query error to a C API error code.
pub fn fromQueryError(err: anytype) Error {
    const query_mod = @import("../core/query.zig");
    const QueryError = query_mod.QueryError;

    return switch (err) {
        QueryError.InvalidData => .buffer_corrupt,
        QueryError.LimitRequired => .limit_required,
        QueryError.TooManyResults => .limit_exceeded,
        QueryError.TooManyFilters => .too_many_filters,
        QueryError.FieldNotFound => .invalid_field,
        QueryError.UnsupportedFieldType => .unsupported_type,
        QueryError.TypeMismatch => .type_mismatch,
        QueryError.OutOfMemory => .out_of_memory,
    };
}

// C-exported functions for error handling
pub fn zdl_last_error() callconv(.c) c_int {
    return @intFromEnum(getError());
}

pub fn zdl_error_message(err: c_int) callconv(.c) [*:0]const u8 {
    const typed_err = std.meta.intToEnum(Error, err) catch return "Unknown error";
    return errorMessage(typed_err);
}
