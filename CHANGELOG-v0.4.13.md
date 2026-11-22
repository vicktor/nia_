# Nia v0.4.13 — Monospace font settings

- Enumerates system-installed monospaced font faces through NSFontManager / NSFont.isFixedPitch.
- Preferences → Appearance includes a font picker, 9–32 pt size slider and live preview.
- Saves PostScript font name and point size in UserDefaults via AppStorage.
- Applies appearance settings live to both Metal split panels; regenerates glyph atlas and updates PTY dimensions.
- Falls back to the system monospace font if a selected font is no longer installed.
- Retains all scrollback, backup, handoff and file-drop features from v0.4.12.

Requires compilation and visual testing on macOS; not built in this Linux environment.
