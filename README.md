# zdl - Zero Data Layer

Fast, type-safe data serialization for Zig with schema evolution, C FFI, and Python bindings.

## Features

- **Comptime schema validation** with explicit TigerStyle bounds
- **CPU-target serialization** with CRC32 protection
- **Type-safe migrations** (v1 ↔ v2 ↔ v3)
- **Changeset validation** (Ecto-style) with bounded errors
- **Zero-copy querying** over serialized payloads
- **Target-specific layouts** (CPU, disk, network)
- **Full C FFI** with query, iterator, and introspection APIs
- **Python bindings** with ctypes and dataclass support

## Installation

Add zdl to your project:

```sh
zig fetch --save git+https://github.com/your-org/zdl
```

Configure your `build.zig`:

```zig
const zdl_dep = b.dependency("zdl", .{
    .target = target,
    .optimize = optimize,
});

// Add zdl to your module
exe.root_module.addImport("zdl", zdl_dep.module("zdl"));
```

## Quick Start

```zig
const zdl = @import("zdl");

const User = struct {
    id: u64,
    name: [32]u8,

    pub const zdl_config = .{ .version = 1 };
};

// Serialize
const bytes = try zdl.serialize.serialize(user, .cpu, allocator);
defer allocator.free(@constCast(bytes));

// Deserialize
const loaded = try zdl.deserialize.deserialize(User, bytes, allocator);
```

## C FFI Generation

zdl provides first-class C interop. Define your schemas, register them, and zdl generates a shared library with C-callable functions plus matching headers.

### 1. Define Schemas

Create `src/schemas.zig`:

```zig
const zdl = @import("zdl");

pub const User = struct {
    id: u64,
    name: [32]u8,
    score: f32,

    pub const zdl_config = .{ .version = 1 };
};

pub const Event = struct {
    timestamp: u64,
    kind: u8,
    payload: [256]u8,

    pub const zdl_config = .{ .version = 1 };
};

// Register types for C export
pub const registry = [_]zdl.SchemaDescriptor{
    .{ .Type = User, .c_prefix = "user" },
    .{ .Type = Event, .c_prefix = "event" },
};
```

### 2. Create Library Root

Create `src/lib_root.zig`:

```zig
const zdl = @import("zdl");
const schemas = @import("schemas.zig");

comptime {
    zdl.exportCApi(&schemas.registry);
}
```

### 3. Build and Generate

```sh
# Build shared library and generate headers
zig build

# Headers are generated in zig-out/include/
# - zdl.h (common types)
# - user.h, event.h (per-schema)
```

### C API Reference

#### Common Header (`zdl.h`)

```c
#include "zdl.h"

// Error handling
zdl_error_t zdl_last_error(void);
const char* zdl_error_message(zdl_error_t err);

// Error codes
typedef enum {
    ZDL_OK = 0,
    ZDL_ERR_NULL = 1,
    ZDL_ERR_INVALID_FIELD = 2,
    ZDL_ERR_TYPE_MISMATCH = 3,
    ZDL_ERR_CORRUPT = 4,
    ZDL_ERR_OOM = 5,
    ZDL_ERR_LIMIT_EXCEEDED = 6,
    ZDL_ERR_LIMIT_REQUIRED = 7,
    ZDL_ERR_TOO_MANY_FILTERS = 8,
    ZDL_ERR_ITER_NOT_STARTED = 9,
    ZDL_ERR_UNSUPPORTED_TYPE = 10
} zdl_error_t;

// Comparison operators
typedef enum {
    ZDL_EQ = 0,  // Equal
    ZDL_NE = 1,  // Not equal
    ZDL_LT = 2,  // Less than
    ZDL_LE = 3,  // Less than or equal
    ZDL_GT = 4,  // Greater than
    ZDL_GE = 5   // Greater than or equal
} zdl_cmp_t;

// Field types for introspection
typedef enum {
    ZDL_TYPE_BOOL, ZDL_TYPE_I8, ZDL_TYPE_I16, ZDL_TYPE_I32, ZDL_TYPE_I64,
    ZDL_TYPE_U8, ZDL_TYPE_U16, ZDL_TYPE_U32, ZDL_TYPE_U64,
    ZDL_TYPE_F32, ZDL_TYPE_F64, ZDL_TYPE_BYTES, ZDL_TYPE_STRUCT
} zdl_field_type_t;

// Field info for runtime introspection
typedef struct {
    const char* name;
    zdl_field_type_t type;
    size_t offset;
    size_t size;
    size_t array_len;
} zdl_field_info_t;
```

#### Per-Schema Functions (25 per schema)

| Category | Function | Signature |
|----------|----------|-----------|
| **Serialize** | `{prefix}_serialize` | `uint8_t* (const T* value, zdl_target_t target, size_t* out_len)` |
| | `{prefix}_deserialize` | `T* (const uint8_t* bytes, size_t len)` |
| | `{prefix}_free` | `void (void* ptr)` |
| | `{prefix}_serialize_array` | `uint8_t* (const T* items, size_t count, zdl_target_t target, size_t* out_len)` |
| | `{prefix}_array_count` | `uint64_t (const uint8_t* bytes, size_t len)` |
| **Query** | `{prefix}_query_new` | `struct {prefix}_query* (const uint8_t* bytes, size_t len)` |
| | `{prefix}_query_free` | `void (struct {prefix}_query* q)` |
| | `{prefix}_query_filter_u64` | `zdl_error_t (struct {prefix}_query* q, const char* field, zdl_cmp_t cmp, uint64_t value)` |
| | `{prefix}_query_filter_i64` | `zdl_error_t (struct {prefix}_query* q, const char* field, zdl_cmp_t cmp, int64_t value)` |
| | `{prefix}_query_filter_f32` | `zdl_error_t (struct {prefix}_query* q, const char* field, zdl_cmp_t cmp, float value)` |
| | `{prefix}_query_filter_f64` | `zdl_error_t (struct {prefix}_query* q, const char* field, zdl_cmp_t cmp, double value)` |
| | `{prefix}_query_filter_bool` | `zdl_error_t (struct {prefix}_query* q, const char* field, zdl_cmp_t cmp, bool value)` |
| | `{prefix}_query_limit` | `zdl_error_t (struct {prefix}_query* q, size_t limit)` |
| | `{prefix}_query_offset` | `zdl_error_t (struct {prefix}_query* q, size_t offset)` |
| | `{prefix}_query_collect` | `T* (struct {prefix}_query* q, size_t* out_count)` |
| | `{prefix}_query_count` | `uint64_t (struct {prefix}_query* q)` |
| **Iterator** | `{prefix}_query_iter_start` | `zdl_error_t (struct {prefix}_query* q)` |
| | `{prefix}_query_iter_next` | `const T* (struct {prefix}_query* q)` |
| | `{prefix}_query_iter_reset` | `void (struct {prefix}_query* q)` |
| **Introspection** | `{prefix}_field_count` | `size_t (void)` |
| | `{prefix}_field_info` | `const zdl_field_info_t* (size_t index)` |
| | `{prefix}_field_by_name` | `const zdl_field_info_t* (const char* name)` |
| | `{prefix}_struct_size` | `size_t (void)` |

### C Query Example

```c
#include "ffi_user.h"

int main(void) {
    // Serialize test data
    FfiUser users[100];
    // ... populate users ...

    size_t len = 0;
    uint8_t *bytes = ffi_user_serialize_array(users, 100, ZDL_TARGET_CPU, &len);

    // Create query
    struct ffi_user_query *q = ffi_user_query_new(bytes, len);

    // Filter: score >= 85
    ffi_user_query_filter_f32(q, "score", ZDL_GE, 85.0f);
    ffi_user_query_limit(q, 50);

    // Collect results
    size_t count = 0;
    FfiUser *results = ffi_user_query_collect(q, &count);

    for (size_t i = 0; i < count; i++) {
        printf("id=%llu score=%.1f\n", results[i].id, results[i].score);
    }

    // Cleanup
    ffi_user_free(results);
    ffi_user_query_free(q);
    ffi_user_free(bytes);
}
```

---

## Python Bindings

zdl generates Python bindings with ctypes and dataclass support.

### Generate Python Module

```sh
zig build gen-python
# Output: zig-out/python/zdl.py
```

### Python Usage

```python
from zdl import FfiUser, FfiUserQuery, Target

# Create and serialize
user = FfiUser(id=42, score=3.14, name=b"alice")
data = user.serialize(Target.CPU)

# Deserialize
user2 = FfiUser.deserialize(data)

# Serialize array
users = [FfiUser(id=i, score=i*10.0) for i in range(100)]
array_data = FfiUser.serialize_array(users, Target.CPU)

# Query with fluent API
query = FfiUserQuery(array_data)
results = (query
    .filter("score", ">=", 50.0)
    .filter("id", "<", 80)
    .limit(20)
    .collect())

for user in results:
    print(f"id={user.id} score={user.score}")

# Iterator interface
for user in FfiUserQuery(array_data).filter("score", ">", 90):
    print(user)

# Count without collecting
count = FfiUserQuery(array_data).filter("score", ">=", 50).count()

# Introspection
print(f"Fields: {FfiUser.field_count()}")
print(f"Struct size: {FfiUser.struct_size()} bytes")
```

### Python Query Operators

| Operator | String aliases |
|----------|---------------|
| Equal | `"=="`, `"="`, `"eq"` |
| Not Equal | `"!="`, `"<>"`, `"ne"` |
| Less Than | `"<"`, `"lt"` |
| Less/Equal | `"<="`, `"le"` |
| Greater Than | `">"`, `"gt"` |
| Greater/Equal | `">="`, `"ge"` |

---

## Examples

The `examples/` directory contains complete working examples:

- `basic_usage.zig` – Serialize/deserialize basics
- `migrations.zig` – Schema evolution
- `validation.zig` – Changeset validation workflow
- `query.zig` – Zero-copy query builder
- `c_usage/` – C program linking against zdl
- `c_query/` – C query API demonstration

Run with `zig build example-basic_usage` (etc).

## Performance

| Operation | Throughput |
|-----------|------------|
| Serialization | >100 MB/sec |
| Deserialization | >100 MB/sec |
| Query iteration | >100 MB/sec |

Run benchmarks: `zig build benchmark-serialize`, `zig build benchmark-query`

---

## Schema Definition

### Basic Schema

```zig
const zdl = @import("zdl");

pub const User = struct {
    id: u64,
    name: [32]u8,
    email: [64]u8,
    score: f32,
    created_at: u64,

    pub const zdl_config = .{
        .version = 1,
    };
};
```

### Supported Types

**Primitives:**
- Integers: `u8`, `u16`, `u32`, `u64`, `u128`, `i8`, `i16`, `i32`, `i64`, `i128`
- Floats: `f16`, `f32`, `f64`, `f128`
- Bool: `bool`

**Composites:**
- Fixed arrays: `[N]T`
- Packed structs
- Nested structs

**Restrictions:**
- No pointers, slices, optionals, or error unions
- No `usize` (use explicit `u32`/`u64`)
- Max array size: 65,536 elements
- Max nesting: 8 levels

### Target-Specific Layouts

```zig
pub const Signal = struct {
    timestamp: u64,
    values: [1024]f32,
    flags: u8,

    pub const zdl_config = .{
        .version = 1,
        .layout = .{
            .cpu = .{ .align_to = 64, .simd_friendly = true },
            .disk = .{ .align_to = 4096, .packed = true },
            .network = .{ .packed = true, .big_endian = true },
        },
    };
};
```

## Schema Evolution

```zig
pub const UserV1 = struct {
    id: u64,
    name: [32]u8,

    pub const zdl_config = .{ .version = 1 };
};

pub const UserV2 = struct {
    id: u64,
    name: [32]u8,
    email: [64]u8,

    pub const zdl_config = .{
        .version = 2,
        .migrations = .{
            .from_v1 = struct {
                pub fn up(v1: UserV1) UserV2 {
                    return .{
                        .id = v1.id,
                        .name = v1.name,
                        .email = [_]u8{0} ** 64,
                    };
                }

                pub fn down(v2: UserV2) UserV1 {
                    return .{ .id = v2.id, .name = v2.name };
                }
            },
        },
    };
};

// Usage
const v2 = zdl.migrate(UserV1, UserV2, v1_data);
```

## Validation

```zig
pub const zdl_config = .{
    .version = 1,
    .changeset = struct {
        pub fn validate(params: anytype, allocator: std.mem.Allocator) !zdl.changeset.Changeset(User) {
            var cs = zdl.changeset.Changeset(User).init(allocator);
            errdefer cs.deinit();

            try cs.cast(params, comptime &.{ "id", "name", "email", "score" });
            try cs.validateRequired(&.{ "id", "name", "email" });
            try cs.validateLength("name", .{ .min = 3, .max = 32 });
            try cs.validateNumber("score", .{ .min = 0, .max = 1000 });

            return cs;
        }
    },
};
```

## Querying (Zig)

```zig
var qb = zdl.query.query(Event, bytes, allocator);
defer qb.deinit();

_ = try qb.filter("status", .eq, @as(u8, 1));
_ = try qb.filter("duration_ms", .lt, @as(u64, 10_000));
_ = qb.limit(50);

var it = try qb.iter();
while (it.next()) |record| {
    // Zero-copy pointer into serialized buffer
}
```

## Core Principles

1. **Comptime everything** – Layout, validation, migration logic resolved at compile time
2. **Target-optimal** – Same schema compiles to optimal layouts per target
3. **Zero parsing** – Serialized format IS the in-memory format where possible
4. **Type safety** – Invalid schemas fail at comptime
5. **Universal interop** – C FFI enables any language to use zdl schemas
6. **No runtime dependencies** – Works on bare metal, WASM, or hosted

---

**Version:** 0.2.0
**Zig:** 0.15.1+
**Philosophy:** TigerStyle – Safety, Performance, Developer Experience
