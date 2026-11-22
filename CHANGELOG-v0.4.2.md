# Nia v0.4.2 — configurable scrollback

- Preferences → Terminal: memory scrollback cap 1,000–100,000 lines (default 10,000).
- On restart, new PTYs use that cap; memory limits are per session.
- Metal view scroll wheel and trackpad navigate the vt100 historical grid.
- Hide live cursor when scrolled away from latest output.
- Does not change SQLite or delete persisted output history; disk retention remains independent.

Note: VT scrollback is RAM-backed and the limit is set when a PTY is created. An active session needs reopening/restarting Nia to adopt a new limit. This is not yet disk-paged infinite scrollback.
