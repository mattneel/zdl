# Changelog

## [0.1.0] - Phase 1 Complete

### Added
- Comptime schema validation with TigerStyle guard rails
- CPU-target serialization/deserialization with canonical CRC32 headers
- Type-safe manual migrations (v1 ↔ v2 ↔ v3)
- Changeset validation framework
- Built-in validators (email, URL, alphanumeric)
- Zero-copy query engine with bounded filters and limits
- Array serialization format for bulk payloads
- Target-specific layouts (CPU, disk, network) with endian-aware transforms
- C FFI exports (`libzdl.so` + generated headers via `zig build`/`zig build gen-headers`)
- Golden C example (`examples/c_usage`) with valgrind-clean smoke test
- Comprehensive test suite (53 tests, all green)
  - Expanded to 61 tests covering layouts and targets
- Usage examples (`examples/`) covering serialization, migrations, validation, and queries
- Benchmark drivers (`benchmarks/`) for serialization, deserialization, and query iteration

### Performance
- Serialization: >100 MB/sec
- Deserialization: >100 MB/sec
- Query iteration: >100 MB/sec (zero-copy)

### Documentation
- README quick start and roadmap
- Contributor guide (`AGENTS.md`)
- Phase-tracked roadmap (`ROADMAP.md`)
- Inline API documentation and examples

### Known Limitations
- GPU layouts stubbed (CUDA/Metal planned for Phase 2.5)
- Manual migration chains (no automatic chain discovery yet)
- Basic filter operators (AND logic, six comparison ops)
- No SIMD or multi-threaded query acceleration yet
