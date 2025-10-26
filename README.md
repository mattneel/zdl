# zdl: Zero Data Layer

**Version:** 0.1.0  
**Target:** Zig 0.15.1+  
**Status:** Draft Specification  
**Philosophy:** TigerStyle - Safety, Performance, Developer Experience

## TigerStyle Principles

zdl follows TigerStyle discipline throughout:

**Safety:**
- Explicit bounds on all operations (no unbounded loops, allocations, or recursion)
- Fail-fast on invalid input (assertions + error handling)
- Fixed limits prevent resource exhaustion (max array size, nesting depth, etc.)
- All memory ownership explicit (caller owns, must free)
- Zero tolerance for compiler warnings

**Performance:**
- Designed for performance from day one (not optimized later)
- Napkin math validates feasibility before implementation
- Predictable execution paths (CPU cache-friendly, branch-predictor friendly)
- Static allocation during init, minimal runtime allocation
- Batched operations where possible

**Developer Experience:**
- Clear naming with units (timeout_ms, size_bytes)
- Functions ≤70 lines (single responsibility)
- Explicit control flow (no hidden complexity)
- Complete documentation (why, not just what)
- Zero technical debt (do it right the first time)

## Overview

zdl (Zero Data Layer) is a comptime-driven data serialization and schema evolution framework for Zig. It provides zero-overhead serialization to heterogeneous compute targets (CPU, GPU, disk, network, embedded) with type-safe migrations and powerful query capabilities.

### Core Principles

1. **Comptime everything** - All layout, validation, and migration logic resolved at compile time
2. **Target-optimal** - Same logical schema compiles to optimal physical layouts per target
3. **Zero parsing** - Serialized format IS the in-memory format where possible
4. **Type safety** - Invalid schemas or missing migrations fail at comptime
5. **Universal interop** - Single C library enables FFI to any language
6. **No runtime dependencies** - Works on bare metal, WASM, or hosted environments

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

### Supported Field Types

**Primitives (explicitly sized):**
- Integers: `u8`, `u16`, `u32`, `u64`, `u128`, `i8`, `i16`, `i32`, `i64`, `i128`
- Floats: `f16`, `f32`, `f64`, `f128`
- Bool: `bool`

**Composites:**
- Fixed arrays: `[N]T` where N is comptime-known and T is a supported type
- Packed structs: For bit-level control
- Nested structs: Other zdl schemas

**Restrictions (safety and predictability):**
- No pointers (`*T`, `[*]T`) - prevents dangling references
- No slices (`[]T`) - requires comptime-known sizes
- No optional types (`?T`) - use sentinel values instead
- No error unions in data fields - handle errors at API boundaries
- No `usize` or architecture-dependent types - use explicit sizes (u32/u64)
- All types must have comptime-known, fixed size
- Maximum array size: 65,536 elements (prevents unbounded memory)
- Maximum nesting depth: 8 levels (prevents stack overflow during traversal)

### Target-Specific Layouts

```zig
pub const Signal = struct {
    timestamp: u64,
    values: [1024]f32,
    flags: u8,
    
    pub const zdl_config = .{
        .version = 1,
        .layout = .{
            .cpu = .{
                .align_to = 64,        // Cache-line aligned
                .simd_friendly = true,
            },
            .cuda = .{
                .align_to = 128,       // Warp-coalesced
                .soa = true,           // Structure-of-Arrays
            },
            .disk = .{
                .align_to = 4096,      // Page-aligned for O_DIRECT
                .packed = true,
            },
            .network = .{
                .packed = true,
                .big_endian = true,
            },
        },
    };
};
```

## Schema Evolution

Sprint 3 introduces a *manual* migration helper. The framework validates that
your schema declares explicit `from_vX` blocks and provides a thin wrapper that
calls the user-supplied `up`/`down` functions. There is intentionally no
automatic chain resolution yet—contributors chain migrations explicitly so the
control flow stays obvious.

### Defining Migrations

```zig
pub const UserV1 = struct {
    id: u64,
    name: [32]u8,
    
    pub const zdl_config = .{
        .version = 1,
    };
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
                    return .{
                        .id = v2.id,
                        .name = v2.name,
                    };
                }
            },
        },
    };
};
```

### Using `zdl.migrate()`

```zig
const zdl = @import("zdl");

const v1 = UserV1{ .id = 42, .name = my_name }; // version = 1
const v2 = zdl.migrate(UserV1, UserV2, v1);     // invokes UserV2.zdl_config.migrations.from_v1.up
const back_to_v1 = zdl.migrate(UserV2, UserV1, v2); // invokes down

// Chaining remains explicit so contributors can audit migrations:
const v3 = zdl.migrate(UserV2, UserV3, v2);
```

If a required migration is missing the build fails at comptime with a clear
error. This keeps the current sprint lightweight while leaving the door open
for automatic chaining in a later phase.

## Serialization Guarantees

Serialized payloads are canonicalised before computing the CRC32 checksum so
that Debug and ReleaseFast builds produce the same bytes even when struct
padding differs. All schemas still obey the size and nesting limits outlined
earlier.

## Implementation Status

The `tests/` tree mirrors `src/` and aggregates unit tests through
`tests/main.zig`, which `zig build test` executes in both Debug and ReleaseFast
modes via the build graph. Release validation runs via `zig build test
-Doptimize=ReleaseFast` to ensure deterministic byte output.
