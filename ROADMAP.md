# zdl Implementation Roadmap (TigerStyle)

## Philosophy

**Do it right the first time.** Each phase is complete before moving forward. No technical debt.

## Phase 1: Foundation (v0.1.0)
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

## Phase 2: Multi-Target (v0.2.0)
**Goal:** Proven cross-target reliability

### Must Have
- [ ] Target-specific layouts
  - CPU: cache-line aligned (64 bytes)
  - Disk: page-aligned (4KB)
  - Network: packed, big-endian
- [ ] Endianness handling
  - Explicit conversion functions
  - No implicit conversions
- [ ] C library generation
  - Clean headers (no implementation leakage)
  - Example usage for each target
- [ ] TypeScript bindings (Bun FFI)
  - Memory ownership documented
  - Error handling examples
  - Zero unsafe casts

### Success Criteria
- Works on: x86_64-linux, x86_64-macos, aarch64-linux
- Cross-target serialization validated
- Fuzzer covers all targets
- Benchmarks show consistent performance
- No undefined behavior (UBSAN clean)

### Timeline
4-6 weeks

---

## Phase 3: Validation (v0.3.0)
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

## Phase 4: Query Engine (v0.4.0)
**Goal:** Fast, safe data access

### Must Have
- [x] Basic filtering (CPU array payloads)
  - Max result set: 1M records
  - Max filter depth: 8 levels
  - Explicit `.limit()` required
- [ ] Iterator interface
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

## Phase 5: Distributed (v0.5.0)
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

## Phase 6: GPU Support (v0.6.0)
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

## Phase 7: Bindings (v0.7.0)
**Goal:** Universal accessibility

### Must Have
- [ ] Rust bindings
  - Safe wrappers
  - Lifetime correct
  - Zero unsafe (in public API)
- [ ] Python bindings
  - Type hints
  - Memory safety
  - GC-friendly
- [ ] Go bindings
  - Idiomatic API
  - Error handling
  - CGo optimized

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
