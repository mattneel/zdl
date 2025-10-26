# Repository Guidelines

## Project Structure & Module Organization
Documentation lives at the repository root (`README.md`, `ROADMAP.md`). Place all Zig source under `src/`, grouped by concern: core schema logic in `src/core/`, target-specific layouts in `src/targets/<target>`, and CLI utilities in `src/cli/`. Keep examples in `examples/` and reusable test fixtures in `tests/fixtures/`. When adding assets (benchmarks, diagrams), store them in `docs/` with a matching `.md` explainer so future contributors understand intent.

## Build, Test, and Development Commands
Use `zig build` to compile the library and CLI once `build.zig` lands. Run `zig test src/**/test_*.zig` for focused unit suites and `zig build test` for the full battery. Format all Zig code with `zig fmt src/**/*.zig`. For quick schema validation during development, add targeted scripts under `tools/` (e.g., `tools/validate_schema.zig`) and execute with `zig run tools/validate_schema.zig`.

## Coding Style & Naming Conventions
Follow standard Zig style: four-space indentation, no tabs, maximum line width 100. Embrace TigerStyle principles from `README.md`: functions ≤70 lines, explicit control flow, no hidden allocations. Name files and modules with snake_case (`schema_registry.zig`), public types in PascalCase (`UserMigration`), and compile-time constants in SCREAMING_SNAKE_CASE. Treat warnings as errors; configure `build.zig` accordingly.

## Testing Guidelines
Adopt Zig’s builtin test runner; each public API addition needs a `test "feature description"` block colocated with the implementation. Mirror target coverage goals from the roadmap: 100% coverage on core serialization paths and fuzz targets for each transport. Store long-running fuzzers under `tests/fuzz/` and gate them behind opt-in build modes so CI remains fast. Use deterministic seeds where possible to ease reproduction.

## Commit & Pull Request Guidelines
Once the repository is initialized as a Git project, follow Conventional Commits (`feat:`, `fix:`) to communicate intent crisply. Scope lines should match the directory touched (`feat(core): add fixed-array encoder`). Keep bodies concise, referencing issue IDs when applicable. Pull requests must summarize behavior, list validation steps (`zig build test`, fuzz run durations), and attach relevant benchmarks or schema diffs. For CLI or API changes, include before/after usage snippets so reviewers can reason about developer impact quickly.

## Security & Configuration Tips
Never introduce unbounded allocations or recursion; enforce the limits called out in the roadmap (array ≤65_536, migration chain ≤16). Store environment-specific secrets outside the repo and plumb them via configuration files under `config/`. When adding new serialization targets, document any platform-specific assumptions (alignment, endianness) in `docs/security/<target>.md` so downstream consumers can audit the guarantees.
