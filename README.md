# zdl - Zero Data Layer

Fast, type-safe data serialization for Zig with schema evolution, C FFI, and Python bindings.

## Features

- **Comptime schema validation** with explicit TigerStyle bounds
- **CPU-target serialization** with CRC32 protection
- **Zero-allocation hot path** (`serializeInto` writes into caller buffers)
- **Mutable containers** — in-memory CRUD over serialized containers with
  per-record CRC integrity, tombstone deletes, and generation-fenced views
- **Type-safe migrations** (v1 ↔ v2 ↔ v3)
- **Changeset validation** (Ecto-style) with bounded errors
- **Zero-copy querying** over serialized payloads
- **Target-specific layouts** (CPU, disk, network)
- **Full C FFI** with query, mutable container, iterator, and introspection APIs
- **Python bindings** with ctypes and dataclass support
- **WebAssembly** — freestanding wasm64 module with generated JS (ES module) bindings and TypeScript declarations

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

// Zero-allocation hot path: serialize into a caller buffer
var buf: [zdl.serialize.serializedSize(User, .cpu)]u8 = undefined;
const wire = try zdl.serialize.serializeInto(&buf, user, .cpu);

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
    ZDL_ERR_UNSUPPORTED_TYPE = 10,
    ZDL_ERR_CAPACITY_FULL = 11,
    ZDL_ERR_STALE_VIEW = 12,
    ZDL_ERR_SLOT_OUT_OF_RANGE = 13,
    ZDL_ERR_SLOT_DELETED = 14,
    ZDL_ERR_CHECKSUM = 15,
    ZDL_ERR_VERSION = 16,
    ZDL_ERR_BUFFER_TOO_SMALL = 17,
    ZDL_ERR_DATA_TOO_LARGE = 18
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

#### Per-Schema Functions (42 per schema)

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
| **Zero-alloc** | `{prefix}_serialize_into` | `zdl_error_t (const T* value, uint8_t* dest, size_t dest_len, zdl_target_t target, size_t* out_len)` |
| | `{prefix}_serialized_size` | `size_t (zdl_target_t target)` |
| **Mutable** | `{prefix}_mut_new` | `struct {prefix}_mut* (size_t capacity)` |
| | `{prefix}_mut_load` | `struct {prefix}_mut* (const uint8_t* bytes, size_t len, size_t extra_capacity)` |
| | `{prefix}_mut_free` | `void (struct {prefix}_mut* m)` |
| | `{prefix}_mut_append` | `zdl_error_t (struct {prefix}_mut* m, const T* value, size_t* out_slot)` |
| | `{prefix}_mut_get` | `const T* (struct {prefix}_mut* m, size_t slot)` |
| | `{prefix}_mut_get_verified` | `zdl_error_t (struct {prefix}_mut* m, size_t slot, T* out)` |
| | `{prefix}_mut_update` | `zdl_error_t (struct {prefix}_mut* m, size_t slot, const T* value)` |
| | `{prefix}_mut_delete` | `zdl_error_t (struct {prefix}_mut* m, size_t slot)` |
| | `{prefix}_mut_compact` | `void (struct {prefix}_mut* m)` |
| | `{prefix}_mut_reserve` | `zdl_error_t (struct {prefix}_mut* m, size_t additional)` |
| | `{prefix}_mut_len` | `size_t (const struct {prefix}_mut* m)` |
| | `{prefix}_mut_live` | `size_t (const struct {prefix}_mut* m)` |
| | `{prefix}_mut_generation` | `uint64_t (const struct {prefix}_mut* m)` |
| | `{prefix}_mut_flush` | `uint8_t* (struct {prefix}_mut* m, size_t* out_len)` |
| | `{prefix}_mut_iter_start` | `zdl_error_t (struct {prefix}_mut* m)` |
| | `{prefix}_mut_iter_next` | `const T* (struct {prefix}_mut* m)` |
| | `{prefix}_mut_iter_reset` | `void (struct {prefix}_mut* m)` |

Pointers returned by `mut_get`/`mut_iter_next` point into container storage
and are invalidated by the relocation fences (`mut_compact`, `mut_reserve`).
After a fence, `mut_iter_next` returns NULL with
`zdl_last_error() == ZDL_ERR_STALE_VIEW`; plain end-of-iteration leaves the
error at `ZDL_OK`. Watch `mut_generation` to detect fences.

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

### C Mutable Container Example

```c
#include "ffi_user.h"

int main(void) {
    struct ffi_user_mut *m = ffi_user_mut_new(1024);

    FfiUser u = { .id = 1, .score = 9.5f };
    size_t slot;
    ffi_user_mut_append(m, &u, &slot);

    u.score = 10.0f;
    ffi_user_mut_update(m, slot, &u);          // re-CRCs one record

    FfiUser out;
    ffi_user_mut_get_verified(m, slot, &out);  // integrity-checked point read

    ffi_user_mut_delete(m, slot);              // tombstone: no bytes move
    ffi_user_mut_compact(m);                   // fence: reclaims, bumps generation

    size_t len;
    uint8_t *wire = ffi_user_mut_flush(m, &len); // standard array container

    ffi_user_free(wire);
    ffi_user_mut_free(m);
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

# Mutable container (in-memory CRUD; all reads return copies)
mc = FfiUserMutable(capacity=1024)
slot = mc.append(FfiUser(id=1, score=9.5))
mc.update(slot, FfiUser(id=1, score=10.0))   # re-CRCs one record
user = mc.get_verified(slot)                 # integrity-checked point read
mc.delete(slot)                              # tombstone: no bytes move
mc.compact()                                 # fence: reclaims tombstones

wire = mc.flush()                            # standard array container bytes
mc2 = FfiUserMutable.load(wire)              # validates container CRC
for record in mc2:
    print(record)
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

## WebAssembly

zdl compiles to a freestanding wasm64 module exposing the full C API
surface — no WASI, no libc, no JS runtime dependencies beyond Memory64
(Node ≥ 24, V8 13+, recent Chrome/Firefox). Allocations that cross the
boundary carry a hidden size header so the `{prefix}_free(ptr)` contract
works without malloc.

```sh
zig build wasm -Doptimize=ReleaseSmall   # zig-out/wasm/zdl.wasm (~22 KB)
zig build gen-js                         # zig-out/js/zdl.mjs + zdl.d.mts
```

### JavaScript Usage

```js
import { loadZdl, ZdlError } from "./zdl.mjs";

const zdl = await loadZdl(wasmBytes); // bytes, Module, or fetch() Response
const { FfiUser, FfiUserQuery, FfiUserMutable } = zdl;

// Serialize / deserialize (u64 fields are BigInt)
const data = FfiUser.serialize({ id: 42n, score: 3.14, name: "alice" });
const user = FfiUser.deserialize(data);

// Query
const arr = FfiUser.serializeArray(users);
const hits = new FfiUserQuery(arr)
  .filter("score", ">=", 50.0)
  .limit(20)
  .collect();

// Mutable container (all reads return copies)
const mc = new FfiUserMutable(1024);
const slot = mc.append({ id: 1n, score: 9.5, name: "a" });
mc.update(slot, { id: 1n, score: 10.0, name: "a" });
mc.delete(slot);
mc.compact();
const wire = mc.flush();             // standard array container bytes
const mc2 = FfiUserMutable.load(wire);
```

Pointers and sizes cross the wasm64 boundary as BigInt; the generated
bindings handle the conversions and never cache views across calls
(memory growth detaches ArrayBuffers).

### TypeScript

`gen-js` also emits `zdl.d.mts` — full TypeScript declarations derived
from the schema at comptime. TypeScript consumers get them automatically
when importing `./zdl.mjs`; no toolchain changes for JS consumers. The
types encode what the schema knows: `u64` fields decode as `bigint` (and
accept `bigint | number` on input), `[N]u8` decodes as `Uint8Array` (and
accepts `string | Uint8Array` on input), and `Query.filter()` field names
are a literal union of the schema's numeric fields — typos are compile
errors:

```ts
const zdl: ZdlApi = await loadZdl(wasmBytes);
const u: FfiUser = zdl.FfiUser.deserialize(data);
const id: bigint = u.id;                       // u64 -> bigint
new zdl.FfiUserQuery(arr).filter("score", ">=", 50.0); // "scrose" would not compile
```

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
| Serialization (zero-alloc) | >6M ops/sec, >700 MB/sec |
| Deserialization + CRC verify | >6M ops/sec, >700 MB/sec |
| Query scan (warm) | >500M rows/sec |
| Mutable append / update / verified read | >4M ops/sec |
| Mutable tombstone delete (incl. compaction share) | >50M ops/sec |

Run benchmarks with `-Doptimize=ReleaseFast` (without it they measure Debug builds):

```sh
zig build benchmark-serialize -Doptimize=ReleaseFast
zig build benchmark-deserialize -Doptimize=ReleaseFast
zig build benchmark-query -Doptimize=ReleaseFast
zig build benchmark-crud -Doptimize=ReleaseFast
```

`benchmark-crud` measures all four CRUD letters as real library operations:
the immutable wire path (`wire`) and `zdl.mutable.MutableContainer`
(`mutable` — per-record CRC sidecar, tombstone deletes, compaction fences).

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

## Mutable Containers (Zig)

`zdl.mutable.MutableContainer(T)` provides in-memory CRUD over the standard
array container format. The wire format is unchanged — `load` ingests
containers produced by `serializeArray` (validating the container CRC once)
and `flush` emits one. Between those boundaries integrity moves to a
per-record CRC sidecar, which is what makes mutation affordable: an update
re-CRCs one record instead of the whole container, and `getVerified` gives
integrity-checked random access in O(record).

```zig
var mc = try zdl.mutable.MutableContainer(Event).load(allocator, bytes, 64);
defer mc.deinit();

const slot = try mc.append(.{ .id = 1, .status = 2, .duration_ms = 5 });
try mc.update(slot, .{ .id = 1, .status = 3, .duration_ms = 7 });
const event = try mc.getVerified(slot); // per-record CRC check, returns copy
try mc.delete(slot);                    // tombstone: no bytes move
mc.compact();                           // fence: reclaims, preserves order

const wire = try mc.flush(allocator);   // standard array container
defer allocator.free(wire);
```

**Lifetime contract** (pinned by `tests/core/lifetime_oracle_test.zig`):
zero-copy views (`get`, `view`, `iter`) point into container storage. A
tombstone delete never moves bytes, so existing views keep reading stable
bytes; in-place updates are visible through views without invalidating them.
Records relocate **only** at the named fences — `compact()` and `reserve()` —
which bump the container generation; any older view traps with
`error.StaleView` on its next access. `append` never relocates: it returns
`error.CapacityFull` instead of reallocating under live views.

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
