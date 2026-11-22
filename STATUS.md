# Implementation status

Delivered: a **source-code first draft**, not a compiled executable.

Runtime / functionality claims should be treated as proposed until tested on macOS. The project intentionally does not implement the AI feature yet, nor reliable Python environment discovery, nor a background daemon.

## Suggested first verification on a Mac

1. `cargo check` and fix compiler/API mismatches, if any.
2. `cargo test`.
3. `cargo run --release` and test shell input, copy-on-select, Cmd+K and tab closing.
4. Inspect SQLite under `~/Library/Application Support/ember-terminal/`.
5. Test output persistence across application restarts.

**Security warning:** the log files contain raw output and may contain sensitive data. Avoid using this build against production servers until recording policies, retention, and redaction are implemented.

## v0.1.2
- Enable wgpu Metal backend on macOS when eframe default features are disabled.
- Remove unused Linux X11 and Wayland features from the macOS build.
- No compilation or runtime verification was possible in this environment.
