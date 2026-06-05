# zdl Implementation Roadmap (TigerStyle)

## Philosophy

**Do it right the first time.** Each phase is complete before moving forward. No technical debt.

## Phase 1: Foundation (v0.1.0) ✅
**Goal:** Solid core with bounded, safe operations

### Must Have
- [x] Schema definition with comptime validation
  - Max array size: 65,536 elements
  - Max nesting: 8 levels
  - Explicit sized types only (no usize)
- [x] Basic serialization (CPU target only)
  - File format with 24-byte header
  - CRC32 checksums
  - Max file size: 1 GB
- [x] Manual migrations (v1 ↔ v2)
  - Up/down functions required
  - Explicit chaining (no automatic chain walking yet)
  - Compile-time guard rails when migrations are missing
- [x] C FFI generation
  - `zdl.exportCApi()` for shared library exports
  - `zdl.getExportNames()` for build.zig configuration
  - Header generation via `zdl.codegen.c_header`
  - Full `zig fetch` package support
- [ ] CLI (`new`, `build`, `test`)
  - Functions ≤70 lines
  - Explicit error handling
  - Full test coverage

### Success Criteria
- Zero compiler warnings
- All tests pass (100% coverage on core paths)
- Fuzzer runs 1M iterations without crash
- Documentation complete (every public function)
- Performance: >100 MB/sec serialization
- Napkin math validated with benchmarks

### Timeline
4-6 weeks (no shortcuts)

---

## Phase 2: C API Layer & Language Bindings (v0.2.0) ✅
**Goal:** Full C FFI with query, introspection, and Python bindings

### Must Have
- [x] Target-specific layouts
  - CPU: cache-line aligned (64 bytes)
  - Disk: page-aligned (4KB)
  - Network: packed, big-endian
- [x] Endianness handling
  - Explicit conversion functions
  - No implicit conversions
- [x] C API Query System
  - QueryHandle with lifecycle management
  - Typed filters (u64, i64, f32, f64, bool)
  - Limit/offset pagination
  - Batch collect and count
  - Iterator API (start, next, reset)
- [x] Schema Introspection
  - FieldInfo struct with type, offset, size
  - field_count, field_info, field_by_name, struct_size
  - Runtime type identification
- [x] Thread-local Error Handling
  - Error codes enum
  - zdl_last_error() and zdl_error_message()
- [x] Common Header Generation
  - zdl.h with shared types
  - Per-schema headers include zdl.h
- [x] Python bindings
  - ctypes-based with dataclass wrappers
  - Query class with fluent API
  - Type hints for IDE support
  - `zig build gen-python`
- [x] TypeScript bindings — delivered in v0.3.0 via wasm64 + generated
      `zdl.d.mts` (WASM superseded the Bun FFI approach)
  - Memory ownership documented
  - Error handling examples
  - Zero unsafe casts

### Success Criteria
- Works on: x86_64-linux, x86_64-macos, aarch64-linux
- Cross-target serialization validated
- 25 functions per schema exported
- Python bindings pass import and round-trip tests
- No undefined behavior (UBSAN clean)

### Timeline
4-6 weeks

---

## Phase 2.5: Mutation, Performance & WebAssembly (v0.3.0) ✅
**Goal:** CRUD over containers, honest benchmarks, run everywhere

(Unplanned phase — emerged from the 1M-CRUD-ops/sec gauntlet. The
originally planned v0.3.0 scope, Validation, moves to v0.4.0.)

### Shipped
- [x] Zero-allocation serialization (`serializeInto`, `serializedSize`)
  - Bulk-copy fast path for padding-free types
  - Wire format byte-identical (84,000-case differential fuzz)
- [x] `MutableContainer(T)` — in-memory CRUD over v1 containers
  - Per-record CRC sidecar: O(record) updates and verified point reads
  - Tombstone deletes; relocation only at compact/reserve fences
  - Generation-checked views (`error.StaleView`); lifetime oracle with
    a mutation test of the oracle itself
- [x] C FFI expansion: 42 functions per schema, error codes 11-18,
      `zdl_alloc`/`zdl_free`
- [x] Python `{Type}Mutable` bindings
- [x] wasm64-freestanding target (`zig build wasm`, ~22 KB) with a
      header-prefixed portable allocator (no libc)
- [x] JavaScript ES module + TypeScript declarations (`zig build gen-js`)
- [x] Honest benchmark suite + CRUD benchmark over real operations
- [x] All four CRUD letters >4M ops/sec single-threaded (gate was 1M)

---

## Phase 3: Validation (v0.4.0)
**Goal:** Bulletproof input validation

### Must Have
- [x] Changeset API
  - Max 256 fields
  - Max 64 errors
  - Explicit memory ownership
- [x] Built-in validators
  - Length bounds for byte fields
  - Email shape (`@` plus dot)
  - URL prefix (`http://` or `https://`)
  - Alphanumeric guard
- [ ] Custom validators
  - Pure functions only
  - Bounded execution
  - No allocations in validator

### Success Criteria
- 100% error path coverage
- Validators never panic
- Performance: <1µs per field validation (target)
- Documentation with examples
- Fuzz testing all validators

### Timeline
3-4 weeks

---

## Phase 4: Query Engine Optimization (v0.5.0)
**Goal:** Fast, safe data access

### Must Have
- [x] Basic filtering (CPU array payloads)
  - Max result set: 1M records
  - Max filter depth: 8 levels
  - Explicit `.limit()` required
- [x] Iterator interface
  - Zero-copy views
  - Bounded iteration
  - No hidden allocations
- [ ] SIMD optimization
  - AVX2 for x86_64
  - NEON for aarch64
  - Scalar fallback
- [ ] Parallel queries
  - Max 64 workers
  - Bounded chunk size
  - Work stealing

### Success Criteria
- >100 MB/sec single-threaded throughput (baseline)
- Linear scaling to 16 cores
- No query can exhaust memory
- Cache-friendly access patterns
- SIMD intrinsics validated

### Timeline
6-8 weeks (performance work takes time)

---

## Phase 5: Distributed (v0.6.0)
**Goal:** Safe concurrent data

### Must Have
- [ ] CRDT implementations
  - G-Counter (grow-only)
  - LWW-Register
  - OR-Set
- [ ] Diff/patch generation
  - Minimal binary diffs
  - Bounded diff size
  - Comptime validation
- [ ] Vector clocks
  - Fixed size (max 64 nodes)
  - No dynamic allocation
- [ ] Merge functions
  - Deterministic merging
  - Commutative operations
  - Bounded execution

### Success Criteria
- Convergence proofs (or strong testing)
- No data loss on merge
- Transport-agnostic
- Performance: <10µs per merge
- Fuzz testing all merge paths

### Timeline
6-8 weeks (distributed systems are hard)

---

## Phase 6: GPU Support (v0.7.0)
**Goal:** Heterogeneous compute

### Must Have
- [ ] CUDA target
  - Warp-aligned (128 bytes)
  - Coalesced memory access
  - Max 48KB shared mem
- [ ] Metal target
  - Threadgroup alignment
  - Argument buffers
- [ ] Transfer operations
  - CPU ↔ GPU
  - Async with streams
  - Pinned memory

### Success Criteria
- Zero-copy transfers where possible
- GPU kernel validation
- Memory alignment verified
- Performance: >10 GB/sec PCIe
- Works on: NVIDIA, AMD, Apple Silicon

### Timeline
8-10 weeks (GPU debugging is slow)

---

## Phase 7: Additional Language Bindings (v0.8.0)
**Goal:** Universal accessibility

### Must Have
- [ ] Rust bindings
  - Safe wrappers
  - Lifetime correct
  - Zero unsafe (in public API)
- [ ] Go bindings
  - Idiomatic API
  - Error handling
  - CGo optimized
- [x] TypeScript bindings — shipped in v0.3.0
  - WASM (wasm64-freestanding) with generated `zdl.d.mts`
  - Type-safe wrappers (schema-derived literal unions)
  - Async load (`loadZdl`)

### Success Criteria
- Feels native in each language
- Examples for common patterns
- Memory safety verified
- Performance within 10% of C
- Documentation complete

### Timeline
4-6 weeks per language (12-18 weeks total)

---

## Phase 8: Production Ready (v1.0.0)
**Goal:** Battle-tested reliability

### Must Have
- [ ] Complete documentation
  - Every function documented
  - Migration guides
  - Performance tuning guide
- [ ] Comprehensive examples
  - Basic usage
  - Advanced patterns
  - Real-world scenarios
- [ ] Benchmark suite
  - Against: protobuf, flatbuffers, cap'n proto
  - Published results
  - Reproducible setup
- [ ] Production testing
  - 1B+ operations
  - Multi-month stability
  - Real workloads

### Success Criteria
- Zero known bugs
- Performance targets all met
- Documentation complete
- Production deployments stable
- Community feedback integrated

### Timeline
12-16 weeks (testing takes time)

---

## Total Timeline

**Conservative estimate:** 18-24 months to v1.0
**Aggressive estimate:** 12-15 months

**Why so long?** Zero technical debt means:
- No shortcuts
- Complete testing
- Full documentation
- Real validation

**Result:** Production-ready from day one.

---

## Metrics Throughout

Every phase tracks:
- Compiler warnings: **0**
- Test coverage: **>95%**
- Fuzzer iterations: **>1M per release**
- Performance regression: **<5%**
- Documentation: **100% of public API**
- TODO/FIXME: **0**

---

## Non-Goals

What we're **not** doing:
- SQL interface (too complex, wrong layer)
- Distributed transactions (use CRDT instead)
- Schema registry (users manage schemas)
- GUI tools (CLI is sufficient)
- Cloud hosting (users deploy)

---

## Success Definition

zdl v1.0 is successful when:
1. **Safe:** No crashes on invalid input (fuzzer proven)
2. **Fast:** Meets all performance targets
3. **Clear:** Developers understand it quickly
4. **Reliable:** Runs for months without issues
5. **Complete:** Does what it claims

**Not measured by:** Feature count, user count, stars

**Measured by:** Correctness, performance, clarity

---

## The TigerStyle Way

- Small, focused PRs
- Tests before code
- Documentation with code
- Benchmarks prove claims
- Fuzz testing catches edge cases
- Zero tolerance for warnings
- Do it right once, not three times

**Result:** Software that works. Period.
