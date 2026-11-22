# Nia v0.5.1 — Split focus, selection and resize

- A plain click only focuses the chosen split pane. Dragging at least 4 points begins selection.
- The renderer no longer highlights a single cell on mouse click.
- Paste explicitly focuses its receiving pane and sends clipboard bytes through the session-bound callback.
- Redundant focus requests are avoided when a panel is already active.
- Geometry updates are coalesced over 120 ms, avoiding full ANSI log replays during every pixel movement of the split divider.

The renderer still relies on vt100 to interpret ANSI and has incomplete reflow for complex TUIs.
macOS compilation and interactive tests must be done on a Mac.
