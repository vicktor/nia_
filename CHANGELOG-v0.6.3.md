# nia_ v0.6.3 — Swift titlebar build fix

- Fixes `NSColor` compilation failure: `performAsCurrentDrawingAppearance` returns `Void`; assign the dynamic color inside its closure instead.
- Removes the two Swift compiler warnings caused by the previous incorrect expression.
- Keeps the v0.6.2 Rust cleanup and existing session/storage formats.
- Bumps Cargo and macOS bundle versions to 0.6.3.

Build validation: Swift parsing and shell script syntax verified on Linux; complete AppKit/Metal compilation requires macOS.
