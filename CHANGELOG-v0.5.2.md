# Nia 0.5.2 — Focus and selection

- Fixes Cmd+V routing in split views: only the active AppKit first responder may handle the shortcut.
- Prevents pointer focus events from enqueuing redundant asynchronous focus changes.
- Adds double click word selection and triple click line selection.
- Adds Shift+drag rectangular selection, with column-preserving copy.
- Single click focuses without selecting.

This is a source update; requires macOS build and manual testing.
