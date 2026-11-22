# Nia v0.4.10 — build fix

- Removed assignment to MTKView.isOpaque, which is read-only in AppKit.
- Kept layer opacity and Metal clear-color alpha to preserve experimental transparency.
- Removed obsolete Store::replay method; replay_stream remains the active bounded-memory log path.
- No migration of session storage or workspaces.
- Full macOS build and live transparency must be checked on a Mac.
