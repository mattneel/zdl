# zdl - Zero Data Layer

Fast, type-safe data serialization for Zig with schema evolution and C FFI.

## Features

- **Comptime schema validation** with explicit TigerStyle bounds
- **CPU-target serialization** with CRC32 protection
- **Type-safe migrations** (v1 ↔ v2 ↔ v3)
- **Changeset validation** (Ecto-style) with bounded errors
- **Zero-copy querying** over serialized payloads
- **Target-specific layouts** (CPU, disk, network)
- **C FFI generation** for cross-language interop

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

### 3. Configure Build

In your `build.zig`:

```zig
const std = @import("std");
const zdl_pkg = @import("zdl");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zdl_dep = b.dependency("zdl", .{ .target = target, .optimize = optimize });
    const zdl_mod = zdl_dep.module("zdl");

    // Schemas module
    const schemas_mod = b.createModule(.{
        .root_source_file = b.path("src/schemas.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zdl", .module = zdl_mod }},
    });

    // Library module
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zdl", .module = zdl_mod },
            .{ .name = "schemas", .module = schemas_mod },
        },
    });
    lib_mod.link_libc = true;

    // Export symbols
    const schemas = @import("src/schemas.zig");
    lib_mod.export_symbol_names = zdl_pkg.interop.c_api.getExportNames(&schemas.registry);

    // Build shared library
    const lib = b.addLibrary(.{
        .name = "myschemas",
        .linkage = .dynamic,
        .root_module = lib_mod,
    });
    b.installArtifact(lib);
}
```

### 4. Generate Headers

Create `tools/gen_headers.zig`:

```zig
const std = @import("std");
const zdl = @import("zdl");
const schemas = @import("schemas");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const output_dir = if (args.len > 1) args[1] else "include";
    var dir = try std.fs.cwd().makeOpenPath(output_dir, .{});
    defer dir.close();

    inline for (schemas.registry) |entry| {
        const file_name = entry.c_prefix ++ ".h";
        var file = try dir.createFile(file_name, .{ .truncate = true });
        defer file.close();

        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);

        try zdl.codegen.c_header.generateHeader(entry.Type, buf.writer(allocator));
        try file.writeAll(buf.items);

        std.debug.print("generated {s}\n", .{file_name});
    }
}
```

### C API Reference

Each registered schema exports these functions:

| Function | Signature |
|----------|-----------|
| `{prefix}_serialize` | `uint8_t* (const T* value, zdl_target_t target, size_t* out_len)` |
| `{prefix}_deserialize` | `T* (const uint8_t* bytes, size_t len)` |
| `{prefix}_free` | `void (void* ptr)` |
| `{prefix}_serialize_array` | `uint8_t* (const T* items, size_t count, zdl_target_t target, size_t* out_len)` |
| `{prefix}_array_count` | `uint64_t (const uint8_t* bytes, size_t len)` |

All functions use the C allocator. Free returned buffers with `{prefix}_free()` or `free()`.

## Examples

The `examples/` directory contains complete working examples:

- `basic_usage.zig` – Serialize/deserialize basics
- `migrations.zig` – Schema evolution
- `validation.zig` – Changeset validation workflow
- `query.zig` – Zero-copy query builder
- `c_usage/` – C program linking against zdl

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

## Querying

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

**Version:** 0.1.0
**Zig:** 0.15.1+
**Philosophy:** TigerStyle – Safety, Performance, Developer Experience
