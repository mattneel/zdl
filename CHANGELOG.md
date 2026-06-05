# Changelog

## [Unreleased]

### Added

- Dual-target WebAssembly: `zig build wasm` now also produces `zdl32.wasm`
  alongside `zdl64.wasm`. Memory64 buys >4 GB datasets but draws an
  adoption boundary at recent runtimes (Node >= 24, V8 13+); the 32-bit
  module covers Safari, older Node, and edge runtimes at a <=4 GB ceiling.
- `supportsMemory64()` and `loadZdlAuto({ wasm64, wasm32 })` in the
  generated JS bindings: feature-detect at load time and fetch only the
  module the runtime can run. The bindings adapt to either ABI
  (pointers/sizes are BigInt on wasm64, Number on wasm32); the data model
  is identical on both — u64 fields are always BigInt.

## [0.3.0] - Mutable Containers, Performance & WebAssembly

### Added

**Zero-Allocation Serialization**
- `serializeInto(dest, value, target)` writes into a caller buffer, returns
  the written sub-slice (`error.BufferTooSmall` on undersized dest)
- `serializedSize(T, target)` for comptime buffer sizing
- Comptime bulk-copy fast path: padding-free types marshal as a single
  `@memcpy`; padded structs, bools, and odd-width ints keep the
  deterministic per-field path with zeroed padding

**Mutable Containers**
- `zdl.mutable.MutableContainer(T)` — in-memory CRUD over the v1 array
  container format (wire format unchanged: `load` ingests `serializeArray`
  output, `flush` emits it)
- Per-record CRC32 sidecar (runtime state): updates re-CRC one record
  instead of the whole container; `getVerified` gives integrity-checked
  random access in O(record)
- Tombstone deletes: no bytes move, existing zero-copy views keep reading
  stable bytes, traversals skip the record
- Relocation only at named fences (`compact`, `reserve`): the container
  generation bumps and stale views trap with `error.StaleView`; compaction
  poisons freed slots (0xAA) in safety-checked builds and moves sidecar
  CRCs without recomputing; `reserve` is failure-atomic
- `append` never relocates: `error.CapacityFull` instead of realloc under
  live views
- Lifetime oracle test suite: randomized mutation/view schedules checked
  against a shadow model, plus a mutation test of the oracle itself

**C FFI (42 functions per schema, up from 25)**
- `{prefix}_serialize_into`, `{prefix}_serialized_size`
- `{prefix}_mut_*` (17 functions): new/load/free/append/get/get_verified/
  update/delete/compact/reserve/len/live/generation/flush/iter_start/
  iter_next/iter_reset
- Error codes 11-18: capacity_full, stale_view, slot_out_of_range,
  slot_deleted, checksum_mismatch, version_mismatch, buffer_too_small,
  data_too_large
- Global `zdl_alloc`/`zdl_free` for host-side buffer placement
- Pointer-lifetime protocol: fences invalidate `mut_get`/`mut_iter_next`
  pointers; after a fence `mut_iter_next` returns NULL with
  `ZDL_ERR_STALE_VIEW`; `mut_generation` exposes the fence counter

**Python Bindings**
- `{Type}Mutable` class with the full CRUD lifecycle; all reads return
  copies so pointer lifetimes never leak into Python

**WebAssembly**
- `zig build wasm` — wasm64-freestanding module (~22 KB ReleaseSmall)
  exposing the full C API surface; requires Memory64 (Node >= 24, V8 13+)
- Portable allocation layer: freestanding allocations carry a 16-byte
  header (length + canary) over `std.heap.wasm_allocator`, preserving the
  free-by-bare-pointer contract without libc
- `zig build gen-js` — `zdl.mjs` ES module (BigInt at the wasm64 boundary,
  views never cached across calls) plus `zdl.d.mts` TypeScript
  declarations derived from the schema at comptime (u64 -> bigint,
  schema-derived `filter()` field-name literal unions)

**Benchmarks**
- `zig build benchmark-crud` — all four CRUD letters as real library
  operations across the immutable wire path and MutableContainer

### Changed

- Benchmarks measure honestly: `smp_allocator` instead of the
  GeneralPurposeAllocator/DebugAllocator, per-iteration input variation and
  `doNotOptimizeAway` sinks, reported bytes match actual wire length, and
  the query benchmark separates one-time container CRC validation from pure
  scan throughput
- `format.canonicalize` and `format.schemaVersion` are now public
- `MutableContainer.load` rejects schema version drift
  (`error.VersionMismatch`)
- Shared library now carries a semantic version (soname)

### Fixed

- Serialization was ~90x slower than deserialization: per-element array
  marshaling (one 1-byte copy per element) replaced by bulk copies; the
  serialize benchmark also measured the debug allocator's page churn
  rather than the library
- Latent buffer overrun serializing ints whose ABI size exceeds their wire
  size (e.g. u24)
- C wrappers (`serialize`, `deserialize`, `serialize_array`, `array_count`)
  returned null on failure without setting the thread-local error code;
  callers checking `zdl_last_error()` saw stale state

### Performance

| Operation | Throughput |
|-----------|------------|
| serializeInto (zero-alloc, 112 B record) | ~6.4M ops/sec, ~900 MB/sec |
| deserialize + CRC verify | ~6.3M ops/sec, ~900 MB/sec |
| Query scan (warm) | >800M rows/sec |
| MutableContainer append / update / getVerified | ~5-6M ops/sec |
| Tombstone delete (incl. compaction share) | ~80M ops/sec |

Both serialize paths are now CRC-bound; the single-table CRC32
(~600-900 MB/sec) is the next ceiling.

### Tests

- 111 tests (up from 83), including the lifetime oracle, mutable container
  API and wire round-trips, FFI error codes, and export-name coverage
- Wire-format compatibility verified by differential fuzzing against the
  previous serializer (84,000 cases) and load->mutate->flush shadow-model
  fuzzing (1,600 schedules)
- Run `zig build test -Doptimize=ReleaseFast` as well as Debug: optimizer
  behavior (RVO) is semantically relevant to padding determinism

---

## [0.2.0] - C API Layer for FFI Wrapper Generation

### Added

**C API Query System**
- `QueryHandle` wrapper for QueryBuilder with C-safe memory management
- Query lifecycle: `{prefix}_query_new`, `{prefix}_query_free`
- Typed filter functions: `filter_u64`, `filter_i64`, `filter_f32`, `filter_f64`, `filter_bool`
- Pagination: `{prefix}_query_limit`, `{prefix}_query_offset`
- Batch retrieval: `{prefix}_query_collect` returns malloc'd array
- Count without materializing: `{prefix}_query_count`
- Iterator API: `{prefix}_query_iter_start`, `{prefix}_query_iter_next`, `{prefix}_query_iter_reset`
- 25 functions exported per schema (up from 5)

**Schema Introspection**
- `FieldInfo` struct with name, type, offset, size, array_len
- `FieldType` enum for runtime type identification
- `{prefix}_field_count` - number of fields in struct
- `{prefix}_field_info` - get field info by index
- `{prefix}_field_by_name` - lookup field by name
- `{prefix}_struct_size` - size of struct in bytes

**Error Handling**
- `src/export/c_error.zig` with thread-local error state
- Error codes: ok, null_param, invalid_field, type_mismatch, buffer_corrupt, out_of_memory, limit_exceeded, limit_required, too_many_filters, iterator_not_started, unsupported_type
- Global error functions: `zdl_last_error()`, `zdl_error_message()`

**Header Generation**
- `src/codegen/c_common.zig` generates `zdl.h` with common types
- Updated `c_header.zig` to include `#include "zdl.h"` and generate query/introspection declarations
- Per-schema headers now include opaque query handle type

**Python Bindings**
- `tools/gen_python.zig` - Python binding generator
- Generated `zdl.py` with ctypes bindings
- Dataclass wrappers for each schema with serialize/deserialize methods
- Query class with fluent filter API
- Context manager support (`with` statement)
- Iterator protocol support
- Full type hints for IDE support
- `zig build gen-python` build step

**Examples**
- `examples/c_query/main.c` - Demonstrates C query API with filters, iterators, and introspection

### Changed

- `c_api.zig` now exports `c_error` module
- `getExportNames()` returns 25 function names per schema + 2 global error functions
- `root.zig` exports `c_common` in codegen and `c_error` in interop

### Tests

- Extended `tests/export/c_api_test.zig` with:
  - Query handle create/free tests
  - Filter tests (u64, f32)
  - Iterator tests with reset
  - Count vs collect length verification
  - Introspection field info tests
  - Error state tests

---

## [0.1.0] - Phase 1 Complete

### Added

**Core Serialization**
- Comptime schema validation with TigerStyle guard rails
- CPU-target serialization/deserialization with canonical CRC32 headers
- Target-specific layouts (CPU, disk, network) with endian-aware transforms
- Array serialization format for bulk payloads

**Schema Evolution**
- Type-safe manual migrations (v1 ↔ v2 ↔ v3)
- Explicit up/down migration functions
- Compile-time validation of migration chains

**Validation**
- Changeset validation framework (Ecto-style)
- Built-in validators (email, URL, alphanumeric, length, number range)
- Bounded error collection (max 64 errors per changeset)

**Query Engine**
- Zero-copy query builder over serialized payloads
- Filter operators: eq, ne, lt, le, gt, ge
- Bounded results with explicit `.limit()`

**C FFI**
- `zdl.SchemaDescriptor` for registering types
- `zdl.exportCApi()` generates C-callable serialize/deserialize/free functions
- `zdl.getExportNames()` for build.zig symbol export configuration
- `zdl.codegen.c_header.generateHeader()` for C header generation
- Full Zig package support (`zig fetch --save`)

**Examples & Testing**
- Usage examples: basic_usage, migrations, validation, query
- C FFI example with Makefile (`examples/c_usage/`)
- Comprehensive test suite (61 tests)
- Benchmark drivers for serialize, deserialize, query

### Performance

| Operation | Throughput |
|-----------|------------|
| Serialization | >100 MB/sec |
| Deserialization | >100 MB/sec |
| Query iteration | >100 MB/sec |

### Documentation
- README with installation, quick start, and C FFI guide
- ROADMAP.md with phase-tracked development plan
- AGENTS.md contributor guide
- Inline API documentation

### Known Limitations
- GPU layouts stubbed (CUDA/Metal planned for Phase 6)
- Manual migration chains only (no automatic chain discovery)
- Single-threaded query execution (SIMD/parallel planned for Phase 4)
