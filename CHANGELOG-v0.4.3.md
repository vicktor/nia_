# Nia v0.4.3 — Disk-indexed history (experimental)

- Adds `history_lines` in the existing SQLite database, indexed by session and insertion sequence.
- Builds a bounded plain-text index from new PTY output incrementally; the original ANSI .bin log remains unchanged.
- When the VT in-memory scrollback reaches its limit, scrolling further switches to a paged text-only history viewer.
- Only visible rows are returned over the Rust/Swift bridge.
- Important: interactive screen redraws (vim/htop) are not reconstructed as faithful terminal images in deep history.
- Older raw logs are preserved but not automatically indexed in this version.
- The new index is a second copy of potentially sensitive terminal output: protect it and include it in encrypted backups.
- This is not yet a fully virtualized, color-preserving history engine.
