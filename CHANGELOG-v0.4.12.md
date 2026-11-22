# Nia v0.4.12 — scrollback + Finder drop

- Deep scrollback now excludes empty indexed rows and clamps at first non-empty page.
- Stops treating the in-memory VT scroll position as an offset into SQLite text history.
- Finder file/folder drops in Metal terminal insert shell-quoted absolute paths (without Return).
- Re-enables window alpha when terminal opacity is below 100% (experimental: macOS titlebar appearance requires testing).
- Preserves session state, workspace layout, backups, and split view.

**Limitations:** Deep SQLite history is text-only and may differ from the actual VT screen. Counting/offset paging can be expensive for very large histories. True independent titlebar opacity still requires an AppKit composition layer.
