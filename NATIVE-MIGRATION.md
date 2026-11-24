# Nia v0.3.0 — macOS native UI milestone

This is a **source-code migration preview**, not a verified release. Building the SwiftUI application requires macOS 14+, the Xcode command line tools, Rust and restic (for backups).

## Build

```bash
./scripts/build-native-macos.sh
open dist/Nia.app
```

The script builds `libnia_core.dylib` and `nia-backup` in release mode, compiles the native SwiftUI/AppKit frontend with `swiftc`, generates the `Nia.icns` icon and codesigns the bundle locally. `Nia.app` contains the Rust dylib in `Contents/Frameworks` and uses an executable-relative rpath. No Electron or web runtime is used.

**If the native build fails:** retain your old `Nia.app` or continue using `cargo run --release --bin nia`. No database migration or deletion is needed. Please share the exact build error.

## Changes

- Native `NavigationSplitView` sidebar: search, session creation and archive context menu.
- `Settings` scene managed by macOS (⌘,): General, Appearance, Terminal, Backup.
- User theme: System, Light and Dark (`UserDefaults`, independent of old egui settings).
- Native system fonts and SF Symbols for all app controls. Menlo in the terminal.
- ⌘B to collapse sidebar, ⌘1–⌘9 to select sessions.
- Terminal input forwarded from an `NSTextView` subclass to Rust, including Tab, arrows and Ctrl keys.
- Rust `cdylib` FFI retains `portable-pty`, `vt100` and `rusqlite` from the existing code.
- Existing local database and history are reused **in place** from the legacy `ember-terminal` data directory.
- The legacy egui executable (`cargo run --release --bin nia`) and existing backup CLI remain available.

## Important current limitations

This is an incremental migration, **not yet feature-parity** with the egui prototype:

1. The terminal view is a **temporary AppKit text view**, not the promised Metal glyph-atlas renderer. It does not yet accurately render all ANSI colors, alternate-screen apps, terminal scrolling, wide Unicode characters, mouse reporting, or terminal application-specific behavior. Do not use this preview as the only terminal for important work.
2. Shell processes are kept by the Rust core while the Nia process is running. They **will not survive** a complete application exit. That requires the future session daemon.
3. The new native settings page describes backup support but does **not** yet invoke `nia-backup` from UI. Use the working CLI for actual backups, and verify an offsite restore separately.
4. The legacy configuration and the new native UI preferences are separate. The Rust core continues to read the old SQLite/session paths so previous data isn't lost.
5. No official Xcode compile/test is possible in the build environment used to prepare this source archive. Compile on your own Mac and report errors.

## Architecture

```
SwiftUI: WindowGroup + NavigationSplitView + Settings
              | C FFI (NiaBridge.h)
Rust cdylib: nia_core_new / list / open / send / resize / poll / screen
              |              |
       SQLite + shell state    PTY + vt100
```

## Data safety

Before first launch make a backup of Nia using the established `nia-backup` workflow. Do **not** remove `~/Library/Application Support/ember-terminal/` until a separate tested migration is implemented.

## Next phase

Implement a Metal-backed `MTKView` with a glyph atlas and color-cell data from the VT parser; move tab-completion, selection/copy and clipboard input into a precise terminal event layer; integrate backups in the native settings; validate accessibility and benchmark idle CPU/RAM.
