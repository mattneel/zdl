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
4. **Type safety** - Invalid schemas, missing migrations, or bad data fail at compile time
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

### Migrations

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
    email: [64]u8,  // New field
    
    pub const zdl_config = .{
        .version = 2,
        .migrations = .{
            .from_v1 = struct {
                pub fn up(v1: UserV1) UserV2 {
                    return .{
                        .id = v1.id,
                        .name = v1.name,
                        .email = [_]u8{0} ** 64,  // Default
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

### Migration Chain Validation

At compile time, zdl validates:
- All versions have complete migration paths
- `up` and `down` functions exist and type-check
- No gaps in version sequence (v1 → v2 → v3, not v1 → v3)
- Migration graph is acyclic
- Maximum migration chain length: 16 versions (prevents unbounded computation)
- Each migration function must complete in bounded time (no loops over unknown-size data)

**Error handling:**
- Migration failures return explicit error unions
- All errors must be handled at call site
- No silent failures or default values

```zig
// Compile error if migration missing:
pub const UserV3 = struct {
    // ...
    pub const zdl_config = .{
        .version = 3,
        // ERROR at comptime: Missing migration from v2!
    };
};

// Runtime error handling:
const migrated = zdl.migrate(UserV2, data, .v3) catch |err| switch (err) {
    error.InvalidVersion => return error.DataCorrupted,
    error.MigrationFailed => return error.IncompatibleSchema,
};
```

## Changesets and Validation

### Changeset API

**Memory management:**
- All allocations explicit via allocator parameter
- No hidden allocations
- Caller owns memory, must call `deinit()`
- Maximum field count per changeset: 256 (bounded resource usage)
- Maximum error count: 64 (prevents unbounded error collection)

```zig
pub const User = struct {
    id: u64,
    name: [32]u8,
    email: [64]u8,
    score: f32,
    
    pub const zdl_config = .{
        .version = 1,
        .changeset = struct {
            pub fn validate(
                params: anytype,
                allocator: std.mem.Allocator,
            ) !zdl.Changeset(User) {
                var cs = zdl.Changeset(User).init(allocator);
                errdefer cs.deinit();
                
                // Cast with explicit field list (no reflection loops)
                try cs.cast(params, &.{ "name", "email", "score" });
                
                // Validate with explicit bounds
                try cs.validateRequired(&.{ "name", "email" });
                try cs.validateLength("name", .{ 
                    .min = 3,  // Explicit minimum
                    .max = 32, // Must match field size
                });
                try cs.validateFormat("email", zdl.validators.email);
                try cs.validateNumber("score", .{ 
                    .min = 0,     // Explicit bounds
                    .max = 1000,
                });
                
                return cs;
            }
        },
    };
};

// Usage - explicit error handling
const params = .{
    .name = "alice",
    .email = "alice@example.com",
    .score = 100.0,
};

var cs = User.zdl_config.changeset.validate(params, allocator) catch |err| {
    // Handle validation setup errors
    return err;
};
defer cs.deinit(); // Explicit cleanup

if (cs.valid()) {
    const user = try cs.apply();
    defer allocator.free(user); // Explicit memory management
    
    const bytes = try zdl.serialize(user, .disk, allocator);
    defer allocator.free(bytes); // Explicit cleanup
} else {
    // Bounded error iteration
    for (cs.errors.items) |err| {
        std.debug.print("{s}: {s}\n", .{ err.field, err.message });
    }
    return error.ValidationFailed;
}
```

## Serialization API

### Core Functions

**Memory ownership:**
- Caller provides allocator explicitly
- Caller owns returned memory
- All allocations must be freed by caller
- No hidden allocations or global state

**Bounded operations:**
- Maximum serialization size: 1 GB (prevents unbounded memory use)
- Maximum deserialization size: 1 GB
- All operations have explicit timeouts (where applicable)

```zig
// Serialize to bytes
// Caller owns returned memory, must free it
pub fn serialize(
    value: anytype,
    target: Target,
    allocator: std.mem.Allocator,
) ![]const u8

// Deserialize from bytes
// Caller owns returned value
pub fn deserialize(
    comptime T: type,
    bytes: []const u8,
    allocator: std.mem.Allocator,
) !T

// Zero-copy deserialize (when possible)
// No allocation, but lifetime tied to input bytes
// Input bytes must remain valid for lifetime of returned value
pub fn deserializeView(
    comptime T: type,
    bytes: []const u8,
) !*const T

// Transfer between targets
// dest_ptr must be pre-allocated with correct size and alignment
// Returns number of bytes written
pub fn transfer(
    value: anytype,
    dest_ptr: [*]u8,
    dest_len: u32,  // Explicit size, not usize
    transfer_type: TransferType,
) !u32

// Example with explicit error handling and memory management
const user = User{
    .id = 1,
    .name = "alice".*,
    .email = "alice@example.com".*,
    .score = 100.0,
    .created_at = 1234567890,
};

// Serialize - caller owns memory
const bytes = try zdl.serialize(user, .disk, allocator);
defer allocator.free(bytes); // Must free

// Deserialize - caller owns result
const loaded = try zdl.deserialize(User, bytes, allocator);
// For primitives, no explicit free needed (stack allocated)

// Zero-copy view - no allocation, bounded lifetime
const view = try zdl.deserializeView(User, bytes);
// view is valid only while bytes is valid
```

### Target Types

```zig
pub const Target = enum {
    cpu,          // Host CPU with cache-line alignment
    cuda,         // NVIDIA GPU with coalesced memory
    metal,        // Apple GPU
    vulkan,       // Vulkan compute
    disk,         // File system (page-aligned)
    network,      // Wire format (packed, big-endian)
    embedded,     // Microcontroller (minimal, aligned)
    wasm,         // WebAssembly memory
};

pub const TransferType = enum {
    cpu_to_cuda,
    cuda_to_cpu,
    cpu_to_metal,
    metal_to_cpu,
    // ... all combinations
};
```

### File Format

**Layout (all fields little-endian on disk):**
```
Offset  Size  Field           Description
------  ----  -----           -----------
0       4     magic           "zdl\0" (0x7A646C00)
4       4     version_u32     Schema version (1-based)
8       1     target_u8       Target layout used
9       3     reserved_u8_3   Reserved for future use (must be 0)
12      8     length_u64      Data length in bytes
20      4     checksum_u32    CRC32 of data section (optional, 0 if unused)
24      N     data            Serialized struct (N = length_u64)
```

**Bounds and validation:**
- Maximum version: 65,535 (u16 range)
- Maximum data length: 1 GB (1,073,741,824 bytes)
- Reserved bytes must be zero (fail if non-zero for forward compatibility)
- Checksum is CRC32 (polynomial 0x04C11DB7)
- File header is exactly 24 bytes (fixed size)

**Error conditions:**
- Invalid magic → `error.InvalidMagic`
- Unknown version → `error.UnknownVersion`
- Length exceeds limit → `error.DataTooLarge`
- Checksum mismatch → `error.DataCorrupted`
- Non-zero reserved → `error.InvalidFormat`

**Example validation:**
```zig
pub fn validateHeader(bytes: []const u8) !Header {
    if (bytes.len < 24) return error.HeaderTooShort;
    
    const magic = std.mem.readInt(u32, bytes[0..4], .little);
    if (magic != 0x7A646C00) return error.InvalidMagic;
    
    const version = std.mem.readInt(u32, bytes[4..8], .little);
    if (version == 0 or version > 65535) return error.InvalidVersion;
    
    const length = std.mem.readInt(u64, bytes[12..20], .little);
    if (length > 1024 * 1024 * 1024) return error.DataTooLarge;
    
    // Verify reserved bytes are zero
    if (bytes[9] != 0 or bytes[10] != 0 or bytes[11] != 0) {
        return error.InvalidFormat;
    }
    
    return Header{
        .version = @intCast(version),
        .target = @enumFromInt(bytes[8]),
        .length = length,
        .checksum = std.mem.readInt(u32, bytes[20..24], .little),
    };
}

## Query Engine

### Basic Queries

**Bounds and limits:**
- Maximum result set: 1,000,000 records (prevents unbounded memory)
- Maximum filter depth: 8 levels (prevents stack overflow)
- All queries must have explicit limit() or bounded iteration
- Query operations are bounded and interruptible

**Memory ownership:**
- `collect()` allocates and caller owns memory
- `iter()` provides zero-copy views (no allocation)
- All allocated results must be freed by caller

```zig
const users_bytes = try std.fs.cwd().readFileAlloc(
    allocator,
    "users.zdl",
    1024 * 1024, // Explicit 1MB limit
);
defer allocator.free(users_bytes);

// Filter and collect - caller owns result
const results = try zdl.query(User, users_bytes, allocator)
    .filter("score", .gt, 100.0)
    .filter("name", .starts_with, "alice")
    .limit(10) // Explicit limit required
    .collect();
defer allocator.free(results); // Must free

// Iterator pattern (zero-copy, no allocation)
var iter = try zdl.query(User, users_bytes, allocator)
    .filter("score", .between, .{ 50.0, 150.0 })
    .limit(1000) // Maximum iteration bound
    .iter();

// Bounded iteration
var count: u32 = 0;
while (iter.next()) |user| {
    if (count >= 1000) break; // Explicit bound check
    std.debug.print("{s}: {d}\n", .{ user.name, user.score });
    count += 1;
}
```

### Parallel Queries

**Parallelism bounds:**
- Maximum workers: 64 (prevents thread explosion)
- Minimum chunk size: 1024 bytes (prevents excessive overhead)
- Work stealing enabled by default
- Each worker has bounded stack usage (no recursion)

```zig
const results = try zdl.query(User, users_bytes, allocator)
    .filter("score", .gt, 100.0)
    .limit(10000) // Must have explicit limit
    .parallelCollect(.{
        .workers = 8,      // Explicit worker count
        .chunk_size = 4096, // Explicit chunk size in bytes
    });
defer allocator.free(results);
```

### Query Operators

- `.eq`, `.ne` - Equality
- `.lt`, `.le`, `.gt`, `.ge` - Comparison
- `.between` - Range check
- `.starts_with`, `.ends_with`, `.contains` - String operations
- `.in` - Set membership

## CRDT Support

### CRDT Types

```zig
pub const Counter = struct {
    id: u64,
    value: i64,
    
    pub const zdl_config = .{
        .version = 1,
        .crdt = .g_counter,  // Grow-only counter
    };
};

pub const Register = struct {
    id: u64,
    value: [256]u8,
    vector_clock: [8]u64,
    
    pub const zdl_config = .{
        .version = 1,
        .crdt = .{
            .type = .lww_register,  // Last-write-wins
            .clock_field = "vector_clock",
        },
    };
};

pub const Set = struct {
    id: u64,
    items: [256]u64,
    tombstones: [256]bool,
    
    pub const zdl_config = .{
        .version = 1,
        .crdt = .or_set,  // Observed-remove set
    };
};
```

### Generated CRDT Operations

```zig
// Auto-generated merge function
pub fn merge(a: Register, b: Register) Register

// Auto-generated diff
pub fn diff(old: Register, new: Register) Diff(Register)

// Apply diff
pub fn applyDiff(reg: *Register, diff: Diff(Register)) !void
```

## C Library Generation

### Build Configuration

```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Build C library
    const lib = b.addSharedLibrary(.{
        .name = "myapp",
        .root_source_file = b.path("src/schema.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    lib.linkLibC();
    b.installArtifact(lib);
    
    // Generate header
    const header = b.addSystemCommand(&.{
        "zig", "build-lib",
        "-femit-h", "-fno-emit-bin",
        "src/schema.zig",
    });
    b.getInstallStep().dependOn(&header.step);
}
```

### Generated C API

```c
// myapp.h (generated)
#ifndef MYAPP_H
#define MYAPP_H

#include <stdint.h>
#include <stddef.h>

typedef struct User {
    uint64_t id;
    uint8_t name[32];
    uint8_t email[64];
    float score;
    uint64_t created_at;
} User;

typedef enum Target {
    TARGET_CPU = 0,
    TARGET_CUDA = 1,
    TARGET_DISK = 2,
    TARGET_NETWORK = 3,
} Target;

// Serialize to bytes
uint8_t* user_serialize(const User* user, Target target, size_t* out_len);

// Deserialize from bytes
User* user_deserialize(const uint8_t* bytes, size_t len);

// Free allocated memory
void user_free(void* ptr);

#endif // MYAPP_H
```

## Language Bindings

### TypeScript (Bun FFI)

```typescript
import { dlopen, FFIType, suffix } from "bun:ffi";

const lib = dlopen(`libmyapp.${suffix}`, {
  user_serialize: {
    args: [FFIType.ptr, FFIType.u32, FFIType.ptr],
    returns: FFIType.ptr,
  },
  user_deserialize: {
    args: [FFIType.ptr, FFIType.usize],
    returns: FFIType.ptr,
  },
  user_free: {
    args: [FFIType.ptr],
    returns: FFIType.void,
  },
});

export class User {
  constructor(
    public id: bigint,
    public name: string,
    public email: string,
    public score: number,
    public created_at: bigint
  ) {}

  toBytes(target: Target = Target.CPU): Uint8Array {
    // Implementation
  }

  static fromBytes(bytes: Uint8Array): User {
    // Implementation
  }
}
```

### Rust

```rust
#[repr(C)]
pub struct User {
    pub id: u64,
    pub name: [u8; 32],
    pub email: [u8; 64],
    pub score: f32,
    pub created_at: u64,
}

#[repr(u32)]
pub enum Target {
    Cpu = 0,
    Cuda = 1,
    Disk = 2,
    Network = 3,
}

extern "C" {
    fn user_serialize(user: *const User, target: Target, out_len: *mut usize) -> *mut u8;
    fn user_deserialize(bytes: *const u8, len: usize) -> *mut User;
    fn user_free(ptr: *mut std::ffi::c_void);
}

impl User {
    pub fn to_bytes(&self, target: Target) -> Vec<u8> {
        // Safe wrapper
    }
    
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, Error> {
        // Safe wrapper
    }
}
```

### Python

```python
import ctypes
from dataclasses import dataclass
from enum import IntEnum

class Target(IntEnum):
    CPU = 0
    CUDA = 1
    DISK = 2
    NETWORK = 3

@dataclass
class User:
    id: int
    name: bytes
    email: bytes
    score: float
    created_at: int
    
    @staticmethod
    def from_bytes(data: bytes) -> 'User':
        # Implementation
        pass
    
    def to_bytes(self, target: Target = Target.CPU) -> bytes:
        # Implementation
        pass
```

## CLI Tool

### Project Structure

```
zdl/
├── src/
│   ├── cli/
│   │   ├── main.zig          # Entry point
│   │   ├── commands/
│   │   │   ├── new.zig       # New project
│   │   │   ├── add.zig       # Add schema
│   │   │   ├── build.zig     # Build all targets
│   │   │   ├── test.zig      # Run tests
│   │   │   └── bindgen.zig   # Generate bindings
│   │   └── ast/
│   │       └── modify.zig    # AST manipulation
│   ├── core/
│   │   ├── serialize.zig     # Serialization
│   │   ├── changeset.zig     # Validation
│   │   ├── query.zig         # Query engine
│   │   ├── crdt.zig          # CRDTs
│   │   └── migrate.zig       # Migrations
│   └── codegen/
│       ├── c.zig             # C header gen
│       ├── rust.zig          # Rust bindings
│       ├── python.zig        # Python bindings
│       ├── go.zig            # Go bindings
│       └── typescript.zig    # TypeScript bindings
├── templates/
│   └── default/
│       ├── src/
│       │   └── schema.zig
│       ├── build.zig
│       └── zdl.toml
├── build.zig
└── build.zig.zon
```

### Commands

```bash
# Create new project
zdl new myapp

# Add schema
zdl add schema User id:u64 name:string email:string

# Build for all targets
zdl build --all-targets

# Build for specific targets
zdl build --targets=x86_64-linux,wasm32-wasi,aarch64-linux

# Run tests
zdl test

# Generate bindings
zdl bindgen --langs=rust,python,typescript,go

# Validate schemas
zdl validate

# Check migrations
zdl migrate check

# Show schema info
zdl info User
```

### Configuration File

```toml
# zdl.toml
[package]
name = "myapp"
version = "0.1.0"

[build]
targets = [
    "x86_64-linux",
    "x86_64-macos",
    "aarch64-linux",
    "wasm32-wasi",
]

[features]
crdt = true
query = true
parallel = true
simd = true

[bindings]
languages = ["rust", "python", "typescript", "go"]
output_dir = "bindings"

[layout]
default_alignment = 64
enable_compression = false
enable_checksums = true
```

## Implementation Guidelines

### Code Organization (TigerStyle)

**Function design:**
- Maximum function length: 70 lines (promotes single responsibility)
- Parent functions control flow (switch/if statements)
- Helper functions are pure computations (no side effects)
- Leaf functions focused on single, specific operations

**Naming conventions:**
- Use explicit, domain-appropriate names (nouns and verbs)
- Include units in variable names: `timeout_ms`, `size_bytes`, `count_items`
- Place units in descending significance: `latency_ms_max` not `max_latency_ms`
- Avoid ambiguous names like `data`, `temp`, `result` without context

**Control flow:**
- Simple, explicit control flow (avoid deep nesting)
- No recursion (use iteration with explicit bounds)
- Fixed limits on all loops: `for (0..MAX_ITEMS)`, not `while (true)`
- Early returns for error cases (fail fast)

**Memory management:**
- All allocations explicit via allocator parameter
- Static allocation during initialization (no runtime alloc in hot paths)
- Declare variables in smallest possible scope
- Large objects (>16 bytes) passed by const reference

**Error handling:**
- Use assertions for invariants: `assert(index < array.len)`
- Handle all errors explicitly (no ignored errors)
- Pair assertions at entry/exit of critical sections
- Treat compiler warnings as errors (zero tolerance)

**Example - good function structure:**
```zig
// Parent function: controls flow, delegates computation
pub fn processUsers(
    users: []const User,
    threshold: f32,
    allocator: std.mem.Allocator,
) ![]User {
    assert(users.len <= MAX_USERS); // Bound check
    assert(threshold >= 0.0 and threshold <= 1000.0); // Input validation
    
    var results = try std.ArrayList(User).initCapacity(
        allocator,
        users.len, // Pre-allocate to avoid realloc
    );
    errdefer results.deinit();
    
    // Simple loop with explicit bound
    for (users, 0..) |user, i| {
        if (i >= MAX_USERS) break; // Explicit safety bound
        
        // Delegate computation to helper
        if (shouldInclude(user, threshold)) {
            try results.append(user);
        }
    }
    
    return results.toOwnedSlice();
}

// Helper function: pure computation, no side effects
fn shouldInclude(user: User, threshold: f32) bool {
    assert(threshold >= 0.0); // Validate input
    return user.score > threshold and user.name[0] != 0;
}
```

## Implementation Phases

**Zero technical debt commitment:**
- Each phase is complete before moving to next
- No "TODO" or "FIXME" comments in released code
- All tests pass, all assertions hold
- Documentation written alongside code
- Performance targets met before phase completion

### Phase 1: Core (v0.1.0)
- [x] Basic schema definition
- [ ] Serialization/deserialization (CPU target only)
- [ ] Simple migrations (v1 → v2)
- [ ] File format with magic bytes
- [ ] Basic CLI (`new`, `build`, `test`)

### Phase 2: Multi-Target (v0.2.0)
- [ ] Target-specific layouts (CPU, disk, network)
- [ ] Endianness handling
- [ ] Alignment control
- [ ] C library generation
- [ ] TypeScript bindings (via Bun FFI)

### Phase 3: Validation (v0.3.0)
- [ ] Changeset API
- [ ] Built-in validators
- [ ] Custom validation functions
- [ ] Error collection and reporting

### Phase 4: Query (v0.4.0)
- [ ] Basic filtering
- [ ] Iterator interface
- [ ] SIMD-optimized comparisons
- [ ] Parallel query execution

### Phase 5: Distributed (v0.5.0)
- [ ] CRDT support (G-Counter, LWW-Register, OR-Set)
- [ ] Diff/patch generation
- [ ] Vector clocks
- [ ] Merge functions

### Phase 6: GPU (v0.6.0)
- [ ] CUDA target
- [ ] Metal target
- [ ] Vulkan target
- [ ] SoA transformation
- [ ] Transfer operations

### Phase 7: Language Bindings (v0.7.0)
- [ ] Rust bindings
- [ ] Python bindings
- [ ] Go bindings
- [ ] More languages as needed

### Phase 8: Polish (v1.0.0)
- [ ] Documentation
- [ ] Examples
- [ ] Benchmarks
- [ ] Performance tuning
- [ ] Stability guarantees

## Compatibility Guarantees

### Pre-1.0
- Breaking changes allowed
- Migration guides provided
- Deprecation warnings where possible

### Post-1.0
- Semver versioning
- Wire format stability
- API backwards compatibility
- Migration path for breaking changes

## Performance Targets

**Design considerations:**
- Performance designed in from the start (not optimized later)
- Napkin math used to validate feasibility
- Benchmarks required for all critical paths
- No reliance on compiler optimizations for correctness

**Target metrics (on modern x86_64):**
- **Serialization**: <5 CPU cycles per byte (~4GB/s @ 3GHz)
- **Deserialization**: Zero-copy when possible, <3 cycles/byte otherwise (~6GB/s)
- **Query filtering**: SIMD-accelerated, >1GB/s throughput single-threaded
- **Parallel scaling**: Linear up to 16 cores (>16 shows diminishing returns)
- **Memory overhead**: <1% for metadata (24 byte header + data)

**Napkin math example (serialization):**
```
Scenario: Serialize 1M user records at 100 bytes each

1. Total data size:
   1,000,000 records * 100 bytes = 100 MB

2. Expected CPU cycles (5 cycles/byte):
   100 MB * 5 cycles/byte = 500M cycles

3. Time at 3 GHz:
   500M cycles / 3,000M cycles/sec ≈ 0.167 seconds

4. Throughput:
   100 MB / 0.167 sec ≈ 600 MB/sec

This matches our target of ~4GB/s for simpler structs,
accounting for 100-byte records having more field overhead.
```

## Security Considerations

**Fail-fast principle:**
- Invalid input causes immediate error (no silent failures)
- All assertions active in debug and release builds
- Corrupt data detected before processing

**Input validation (defense in depth):**
- **Header validation**: Magic bytes, version range, length bounds checked first
- **Checksum verification**: CRC32 validated before deserialization
- **Size bounds**: All arrays, strings checked against declared sizes
- **Type checking**: Comptime ensures no type confusion possible
- **Alignment verification**: Memory alignment validated before access

**Buffer safety:**
- **Buffer overflow**: Comptime size checks prevent overruns
- **Out-of-bounds**: All array access bounds-checked at runtime
- **Use-after-free**: Impossible (no pointers in data model)
- **Double-free**: Impossible (explicit ownership model)

**Fuzzing integration:**
- All deserialization paths must pass fuzzing
- Minimum 1M fuzz iterations before release
- Corpus includes: valid data, corrupted headers, boundary cases
- No crashes allowed on arbitrary input

**Example validation:**
```zig
pub fn deserialize(
    comptime T: type,
    bytes: []const u8,
    allocator: std.mem.Allocator,
) !T {
    // 1. Validate header (fail fast on bad input)
    const header = try validateHeader(bytes);
    
    // 2. Verify size matches expectation
    const expected_size = @sizeOf(T);
    if (header.length != expected_size) return error.SizeMismatch;
    
    // 3. Verify checksum if present
    if (header.checksum != 0) {
        const actual = std.hash.Crc32.hash(bytes[24..]);
        if (actual != header.checksum) return error.DataCorrupted;
    }
    
    // 4. Bounds check before access
    if (bytes.len < 24 + expected_size) return error.TruncatedData;
    
    // 5. Only now access data
    const data_bytes = bytes[24..][0..expected_size];
    return std.mem.bytesToValue(T, data_bytes);
}

## References

- Zig 0.15.1 Release Notes
- Cap'n Proto wire format
- Apache Arrow memory layout
- Protocol Buffers schema evolution
- CRDTs: Conflict-free Replicated Data Types

## License

MIT or Apache 2.0 (TBD)

---

**Document Version:** 0.1.0  
**Last Updated:** 2025-01-25  
**Authors:** Matt (plus plus)
