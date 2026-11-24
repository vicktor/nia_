# Repository Guidelines

## Project Structure & Module Organization

nia_ is a native macOS terminal with a Rust 2021 core and SwiftUI/AppKit/Metal interface.

- `src/`: FFI/session management (`lib.rs`), PTY lifecycle (`terminal.rs`), SQLite storage, and history; `src/bin/nia-backup.rs` provides backup recovery.
- `native/Sources/`: Swift application, rendering, geometry, and AI features; `native/include/` defines the C bridge.
- `native/Resources/`: English/Spanish localization; `assets/`: app icon; `examples/`: sample configuration.
- Tests live alongside Rust modules, in `native/Tests/`, and in `tests/`. Build scripts live in `scripts/`; generated bundles go to `dist/`.

## Build, Test, and Development Commands

Use macOS 14+, Xcode Command Line Tools, Rust/Cargo, Git, and CMake. The native build also compiles the embedded inference helper and may download dependencies.

- `cargo build --release --lib --bin nia-backup`: build Rust components.
- `./scripts/build-native-macos.sh`: compile and ad-hoc sign `dist/nia_.app`.
- `open dist/nia_.app`: launch locally.
- `cargo fmt --check`: check Rust formatting.
- `cargo test --locked --all-targets`: run Rust tests.
- `python3 -m unittest discover -s tests -p test_build_environment.py -v`: run build-preflight tests.

Run standalone Swift geometry checks with:

```sh
swiftc native/Sources/NiaTerminalGeometry.swift native/Tests/NiaTerminalGeometryTests.swift -o /tmp/nia-geometry-tests
/tmp/nia-geometry-tests
```

## Coding Style & Naming Conventions

Use four-space indentation. Follow rustfmt for Rust, `snake_case` functions/modules, and `PascalCase` types. Swift uses `UpperCamelCase` types and `lowerCamelCase` members. Preserve surrounding style; existing Rust formatting differences are documented, so avoid unrelated reformatting. Keep FFI declarations and implementations synchronized.

## Testing Guidelines

Use Rust `#[test]` cases with descriptive behavior names, standalone Swift checks in `*Tests.swift`, and Python `unittest` cases in `test_*.py`. No coverage threshold is documented. Add regression tests for changed behavior. For UI/PTY bugs, provide reproduction steps; for restoration changes, test two split terminals and restart. Build the native app when app behavior changes.

## Commit & Pull Request Guidelines

History commonly uses `feat:`, `fix:`, `docs:`, and `ui:` prefixes with concise action summaries. Keep PRs focused; discuss major changes in an issue first. Describe behavior, link relevant issues, and report validation. Sanitize logs/screenshots. Update English and Spanish documentation for user-visible changes; retain MPL-2.0 notices.

## Security & Compatibility

Never commit credentials, terminal histories, databases, or local models. Preserve the legacy `ember-terminal` application-data directory and `dev.nia.terminal` bundle identifier.

## Agent Instructions

Prefer codebase-memory-mcp graph tools for code discovery; index unindexed repositories first. Use text search for configuration, literals, or insufficient graph results.
