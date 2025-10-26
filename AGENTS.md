# Repository Guidelines

## Project Structure & Module Organization
Documentation stays at the repository root (`README.md`, `ROADMAP.md`). Core Zig code lives in `src/`: `root.zig` exports the library surface, `main.zig` drives the CLI, and `src/core/` holds shared modules (`schema.zig`, `format.zig`, `serialize.zig`, `deserialize.zig`, `target.zig`, `migrate.zig`, `changeset.zig`, `validators.zig`). Add future modules under `src/<area>/` and keep any runtime helpers alongside the code they serve. House automated tests under `tests/` (mirroring the `src/` tree) so source modules remain uncluttered. Reserve `docs/` for design notes, and treat `zig-out/` as build output that never lands in Git.

## Build, Test, and Development Commands
Run `zig build` to compile the library and install the CLI into `zig-out/bin/zdl`. Use `zig build run -- <args>` for quick manual smoke checks. Execute `zig build test` for the full suite (aggregated via `tests/main.zig`); for focused runs use `zig test tests/<area>/<case>.zig`. Keep formatting clean with `zig fmt src/**/*.zig tests/**/*.zig build.zig`. House experimental utilities under `tools/` and execute them via `zig run tools/<name>.zig`.

## Coding Style & Naming Conventions
Follow standard Zig style: four-space indentation, no tabs, maximum line width 100. Embrace TigerStyle principles from `README.md`: functions ≤70 lines, explicit control flow, no hidden allocations. Name files and modules with snake_case (`schema_registry.zig`), public types in PascalCase (`UserMigration`), and compile-time constants in SCREAMING_SNAKE_CASE. Treat warnings as errors; configure `build.zig` accordingly.

## Testing Guidelines
Adopt Zig’s builtin test runner; author `test "feature description"` blocks in companion files under `tests/` (e.g., `tests/core/schema_test.zig`). Extend the fuzz scaffolding in dedicated `tests/fuzz/` modules and gate expensive fuzzers behind explicit `zig build` steps. Track roadmap coverage targets—100% on serialization primitives and transport migrations—and capture repro inputs under `tests/fixtures/`. Keep an eye on the throughput check in `tests/core/roundtrip_test.zig`, which enforces ≥10 MB/s in Debug builds (≥100 MB/s in Release) for the CPU serializer/deserializer. Manual migration helpers live in `tests/core/migration_test.zig`, while Sprint 4 validation suites live in `tests/core/changeset_test.zig` and `tests/core/validators_test.zig`.

## Commit & Pull Request Guidelines
History currently starts with `Initial scaffold`; from here forward adopt Conventional Commits (`feat:`, `fix:`) so automation can reason about releases. Match scopes to directories (`feat(src/core): add fixed-array encoder`) and keep body text focused on motivation plus validation. Pull requests must describe behavior changes, list verification steps (`zig build`, `zig build test`, fuzz durations), and attach benchmarks or schema diffs when performance or layout shifts. Include CLI/API before-and-after snippets so reviewers can spot downstream impact quickly.

## Security & Configuration Tips
Never introduce unbounded allocations or recursion; enforce the limits called out in the roadmap (array ≤65_536, migration chain ≤16). Store environment-specific secrets outside the repo and plumb them via configuration files under `config/`. When adding new serialization targets, document any platform-specific assumptions (alignment, endianness) in `docs/security/<target>.md` so downstream consumers can audit the guarantees.
