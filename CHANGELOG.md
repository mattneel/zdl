# Changelog

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
