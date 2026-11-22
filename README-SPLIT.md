# Nia 0.4.6: Test plan

Run `./scripts/build-native-macos.sh` on macOS, then `open dist/Nia.app`.

1. Select a session and type immediately (no second click).
2. Drag session rows into a new order. Restart and verify order and Cmd+1…9.
3. Pick **Lado a lado** or **Arriba y abajo** from the split menu. Choose a secondary session using its context menu.
4. Type different commands in each pane, resize window/divider, ensure each PTY keeps its own rows and columns.
5. Click each pane and verify typing goes to that pane. Change sessions from sidebar; focus should return automatically.
6. Restart and verify split orientation and saved secondary session, then check backup.

The existing database is modified in place to add sort_order. Back up the current Nia database first.

The legacy egui binary (`src/main.rs`) remains in the source as an archive but is no longer built. Nia native uses a SwiftUI AppKit front-end and a Rust dylib.
