# nia_ v0.6.2 — Build cleanup

- Replaces invalid `NSColor.resolvedColor(with:)` with `NSAppearance.performAsCurrentDrawingAppearance` to resolve the titlebar system background correctly in light and dark appearance.
- Uses `_ = report(status)` for the intentionally discarded Swift Bool return.
- Removes unused `Path` import and obsolete `Store::log_size`, `Store::history_count`, and `Store::history_page`. The active streaming replay and non-blank paginated scrollback are retained.
- Auto-regenerates llama.cpp's CMake build cache when the source folder is moved.
- Updates Cargo and app bundle version to `0.6.2`.

Full macOS compilation is required before distribution; no macOS AppKit build is available in this environment.
