# Nia v0.4.5 — Session switching / Metal presentation

- Full frame is read and decoded for the target session before the tab is published.
- Explicit frame ownership: SwiftUI never displays a different session's last frame.
- A single MTKView is reused instead of recreating the Metal pipeline and glyph atlas on every tab switch.
- Selection, scroll accumulator and cursor blink reset on session transitions.
- The PTY is resized to the known viewport before the first frame of the next session.
- Frames are only uploaded to Metal if the snapshot revision changes.
- Session color dot is 3.5pt (one quarter the 14pt diameter), with an 18pt hit target.

The historical ANSI replay path is unchanged. Prior logs may still show old interactive screen
state when opening an archived session: precise state restoration requires persisted VT checkpoints.

## Regression checklist

- Rapidly alternate Cmd+1 and Cmd+2 with distinct prompts (100 times).
- Run distinct output in each tab, switch during output, and verify no cross-tab lines.
- Resize the window, then switch between tabs; check wrapping and cursor positions.
- Confirm scroll/selection do not carry between tabs.
- Confirm one Metal view and one glyph atlas survive repeated tab switches.
