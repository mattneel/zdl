# Changelog

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
- GPU layouts stubbed (CUDA/Metal planned for Phase 2)
- Manual migration chains only (no automatic chain discovery)
- Single-threaded query execution (SIMD/parallel planned for Phase 4)
