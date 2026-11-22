# Nia v0.4.6 — Split, focus and ordered sessions

- Focus automatically moves to the terminal when selecting a session.
- Session order persisted in SQLite (`sort_order`) including migration of legacy records.
- Drag and drop reorders sessions; Cmd+number uses persisted order.
- Vertical and horizontal two-pane split, each pane with its own PTY size, viewport and input.
- Split layout and secondary session persist in local macOS preferences.
- Rust: dirs 7, rusqlite 0.43, toml 1.2, zip 9.8 (`SimpleFileOptions`).
- Removes the legacy egui executable and wgpu dependencies from the native build.

**Validation:** Build and runtime test on macOS required. Backup data before first migration.
