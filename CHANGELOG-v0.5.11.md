# Nia v0.5.11 — PTY width fix

- Updates PTY and VT parser dimensions as soon as the pane size changes; no 120 ms delay before telling Zsh the new width.
- Separately debounces expensive ANSI history reflow for 180 ms, preserving Metal rendering responsiveness.
- Adds bridge methods `nia_resize_fast` and `nia_reflow`.
- Keeps per-session geometry independent in split mode.

**Limitation**: text emitted with actual newlines (hard wrapping by the shell, an application, or historical PTY output) cannot be perfectly unwrapped just by resizing. Test new output with `stty size` and `printf '%s\n' ...` after changing the split width. This release is not macOS-build-tested here.
