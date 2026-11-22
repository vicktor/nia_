# nia_ v0.6.4 — Movable titlebar

- Fix a regression where the translucent-window titlebar could not be used to drag the macOS window.
- Let the dedicated titlebar backdrop participate in hit-testing and forward mouse drags to `NSWindow.performDrag(with:)`.
- Keep the native traffic-light controls and the terminal view separate.
- No changes to sessions, history, workspace layout, or saved data.

Validation: Swift parse and Bash syntax checked; macOS AppKit runtime verification still required.
