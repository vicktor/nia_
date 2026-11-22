# Nia v0.5.0 — Remote experimental + reflow first pass

- Native UI: new remote session sheet (SSH host alias + named tmux session).
- Rust: remote session host persisted in SQLite, and SSH attaches to a stable
  remote tmux session. No SSH keys/passwords persisted in Nia.
- SSH strict host-key checking and public-key authentication by default.
- Resize: bounded raw-log ANSI replay at the new width for local, non-alt-screen
  terminals up to 2 MB, preserving per-session history.
- Remote tmux owns remote process lifecycle, so Nia reconnects without
  spawning a new shell if the original tmux session survives.
- Builds on v0.4.13 and retains all existing sessions/backup tables.
- Not a fully general TUI reflow engine; not automatic bidirectional sync.
