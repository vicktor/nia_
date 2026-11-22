# Nia 0.3.1 — Native UX fixes

- Removed custom sidebar toggle from toolbar. Native `NavigationSplitView` owns it; `⌘B` changes its actual column visibility.
- Removed the redundant Settings button from the session toolbar. Use Nia → Settings (`⌘,`).
- Added session-specific #RRGGBB colors, persisted to `session_colors` in the existing SQLite database without changing or deleting session records.
- Added `ColorPicker` in the sidebar and colored session rows, glyphs, and a narrow stripe across the active terminal.
- Implemented ⌘C, ⌘V and ⌘A in the AppKit terminal view; mouse selection retains auto-copy. Pasting still does not support negotiated bracketed-paste mode.
- Cursor drawn by AppKit (not injected into the screen text) with bar, block and underline modes and a 550ms blink timer. Configure in Settings → Appearance.
- Added terminal-panel opacity slider under Appearance. The titlebar remains opaque. **Important:** this is content-panel alpha compositing within the opaque app window; transparent-through-to-the-desktop windows are NOT implemented.
- Existing session logs, settings and backup directories remain untouched.

## Build

```bash
./scripts/build-native-macos.sh
open dist/Nia.app
```

`Swift` syntax parsed on the build environment. Full AppKit linking and Rust compilation must be verified on macOS.

## Known limitations

- Terminal is still based on `NSTextView`; ANSI styles, interactive TUIs, IME, proportional fonts and advanced paste handling are incomplete. Metal text renderer planned.
- Cursor overlay uses monospaced cell metrics. It may visually drift when terminal text wraps or includes double-width Unicode characters.
- Screen snapshots can refresh the view while a selection is active. Copying works, but selection stability during heavy output may be imperfect.
- `session_colors` is created lazily; it will appear in newly created backups from the current SQLite database.
