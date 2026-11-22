# Nia v0.4.11 — scrollback and native toolbar

- Limit indexed-history scrolling to the oldest available full viewport.
- Avoid empty SQLite page at the top of history.
- Move split layout menu into the native SwiftUI toolbar, beside the window title.
- Keep the native window/titlebar opaque; Metal panel alpha blends over the window background.
- Native About Nia panel with version 0.4.11 and a link to https://github.com/vicktor/nia_.
- This does NOT yet provide true see-through-desktop transparency in the content region.
