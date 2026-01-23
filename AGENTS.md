# Repository Guidelines

## Project Structure & Module Organization

Documentation stays at the repository root (`README.md`, `ROADMAP.md`, `CHANGELOG.md`). Core Zig code lives in `src/`: `root.zig` exports the library surface, `main.zig` drives the CLI, and `src/core/` holds shared modules (`schema.zig`, `format.zig`, `serialize.zig`, `deserialize.zig`, `target.zig`, `layout.zig`, `migrate.zig`, `changeset.zig`, `validators.zig`, `query.zig`, `crc.zig`).

Code generation helpers sit under `src/codegen/`:
- `c_header.zig` - Per-schema C header generation
- `c_common.zig` - Common `zdl.h` header generation

The C interop surface lives under `src/export/`:
- `c_api.zig` - C FFI exports (serialize, deserialize, query, introspection)
- `c_error.zig` - Thread-local error handling
- `schemas.zig` - Schema registry for C export

Add future modules under `src/<area>/` and keep any runtime helpers alongside the code they serve.

House automated tests under `tests/` (mirroring the `src/` tree) so source modules remain uncluttered:
- `tests/core/*` - Core module tests
- `tests/codegen/*` - Header generation tests
- `tests/export/*` - C API tests

Tools live under `tools/`:
- `generate_headers.zig` - Header generation tool
- `gen_python.zig` - Python binding generator

Examples live under `examples/`:
- `basic_usage.zig`, `migrations.zig`, `validation.zig`, `query.zig` - Zig examples
- `c_usage/` - Basic C example
- `c_query/` - C query API example

Build outputs go to `zig-out/`:
- `zig-out/lib/libzdl.so` - Shared library
- `zig-out/include/` - Generated headers (`zdl.h`, per-schema headers)
- `zig-out/python/zdl.py` - Generated Python bindings

Reserve `docs/` for design notes. Treat `zig-out/` as build output that never lands in Git.

## Build, Test, and Development Commands

| Command | Description |
|---------|-------------|
| `zig build` | Build library, generate headers in `zig-out/include/` |
| `zig build test` | Run full test suite |
| `zig build test -Doptimize=ReleaseFast --summary all` | Pre-ship validation |
| `zig build gen-headers` | Generate C headers only |
| `zig build gen-python` | Generate Python bindings to `zig-out/python/` |
| `zig build run -- <args>` | Run CLI |
| `zig build example-basic_usage` | Run specific example |
| `zig build benchmark-serialize` | Run serialization benchmark |
| `zig build benchmark-query` | Run query benchmark |
| `zig fmt src/**/*.zig tests/**/*.zig build.zig` | Format code |

For focused test runs: `zig test tests/<area>/<case>.zig`

## Coding Style & Naming Conventions

Follow standard Zig style: four-space indentation, no tabs, maximum line width 100. Embrace TigerStyle principles from `README.md`: functions ≤70 lines, explicit control flow, no hidden allocations. Name files and modules with snake_case (`schema_registry.zig`), public types in PascalCase (`UserMigration`), and compile-time constants in SCREAMING_SNAKE_CASE. Treat warnings as errors; configure `build.zig` accordingly.

## Testing Guidelines

Adopt Zig's builtin test runner; author `test "feature description"` blocks in companion files under `tests/` (e.g., `tests/core/schema_test.zig`). Extend the fuzz scaffolding in dedicated `tests/fuzz/` modules and gate expensive fuzzers behind explicit `zig build` steps. Track roadmap coverage targets—100% on serialization primitives and transport migrations—and capture repro inputs under `tests/fixtures/`.

Key test files:
- `tests/core/roundtrip_test.zig`, `tests/core/integration_test.zig` - Throughput checks
- `tests/core/migration_test.zig` - Manual migration helpers
- `tests/core/changeset_test.zig`, `tests/core/validators_test.zig` - Validation suites
- `tests/core/query_test.zig` - Query coverage
- `tests/codegen/c_header_test.zig` - Header generation
- `tests/export/c_api_test.zig` - C API including query, introspection, error handling

## CRC32 Determinism Rule

**Always zero-fill and write fields individually when serializing.** Padding bytes vary between build modes; bulk `@memcpy` of a struct will corrupt CRC32 determinism. The required pattern is:

1. Zero the entire payload buffer (`@memset`).
2. Walk fields via `writeFieldCanonical` to populate bytes (skip padding).
3. Apply endian swaps per-field when needed.
4. Compute CRC32 only after the canonical write finishes.

Never copy raw struct bytes into the payload. This keeps Debug/Release CRC32 in sync.

## C API Guidelines

The C API exports 25 functions per schema plus 2 global error functions:

**Serialization (5):** serialize, deserialize, free, serialize_array, array_count

**Query (14):** query_new, query_free, query_filter_u64/i64/f32/f64/bool, query_limit, query_offset, query_collect, query_count, query_iter_start, query_iter_next, query_iter_reset

**Introspection (4):** field_count, field_info, field_by_name, struct_size

**Global (2):** zdl_last_error, zdl_error_message

When modifying the C API:
1. Update `src/export/c_api.zig` with new exports
2. Update `src/export/c_error.zig` if adding error codes
3. Update `src/codegen/c_header.zig` for declaration generation
4. Update `src/codegen/c_common.zig` for common types
5. Run `zig build` to regenerate headers
6. Update tests in `tests/export/c_api_test.zig`
7. Update Python generator in `tools/gen_python.zig`
8. Update documentation (README.md, CHANGELOG.md)

## Commit & Pull Request Guidelines

History currently starts with `Initial scaffold`; from here forward adopt Conventional Commits (`feat:`, `fix:`) so automation can reason about releases. Match scopes to directories (`feat(src/core): add fixed-array encoder`) and keep body text focused on motivation plus validation. Pull requests must describe behavior changes, list verification steps (`zig build`, `zig build test`, fuzz durations), and attach benchmarks or schema diffs when performance or layout shifts. Include CLI/API before-and-after snippets so reviewers can spot downstream impact quickly.

## Security & Configuration Tips

Never introduce unbounded allocations or recursion; enforce the limits called out in the roadmap (array ≤65_536, migration chain ≤16). Store environment-specific secrets outside the repo and plumb them via configuration files under `config/`. When adding new serialization targets, document any platform-specific assumptions (alignment, endianness) in `docs/security/<target>.md` so downstream consumers can audit the guarantees.

When touching the C surface:
1. Update `src/export/schemas.zig` if adding schemas
2. Run `zig build` to refresh headers
3. Validate with C example: `gcc -I zig-out/include -L zig-out/lib -lzdl examples/c_query/main.c -o test && LD_LIBRARY_PATH=zig-out/lib ./test`
4. Run valgrind: `LD_LIBRARY_PATH=zig-out/lib valgrind ./test`
