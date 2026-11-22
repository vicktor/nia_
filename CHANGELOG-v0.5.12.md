# Nia 0.5.12 – Stable resize and workspace layout

- Workspace JSON with missing optional `primary` or `secondary` is accepted (Swift `Codable` omits nil fields).
- Live PTY resize is immediate without ANSI log replay. Both `nia_resize` and `nia_resize_fast` use the same safe path.
- `nia_reflow` remains exported as a no-op for ABI compatibility with older frontends; true reflow requires tracking logical lines with wrap metadata.
- Swift removes delayed ANSI replay calls after resize, avoiding repeated prompts/output on split drag and font changes.
- No changes to database schema or stored history.

**Trade-off:** historical lines already hard-wrapped will not always reflow. New output uses the current PTY width.

Validation: static checks only; compilation/runtime on macOS not performed here.
