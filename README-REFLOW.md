# Nia v0.5.0 — ANSI-log reflow on resize (first implementation)

The `vt100` parser resizes its grid but does not fully rewrap historical cells.
For local **main-screen** sessions, Nia now rebuilds the parser from the original
preserved ANSI log **when the PTY width changes**, processing the log at the new
column count. This retains ANSI attributes and restores content in simple shell
output such as `ls -la` that wrapped at the old width.

To keep resizing responsive, this first pass only replays logs up to **2 MB**.
For larger histories Nia preserves the old VT resize behavior and the indexed
scrollback. We will replace this replay approach with incremental logical-line
checkpoints for large sessions.

Never apply this reflow to an active **alternate screen** (vim/htop) or a
remote tmux PTY. These programs should repaint after receiving PTY SIGWINCH.
An application that emits width-dependent ANSI cursor positioning may still
need an explicit refresh (Ctrl-L) in this version. This is **not yet a full
terminal-grade reflow engine** for arbitrary TUI programs.

Test: `ls -la` with long filenames, resize split wide/narrow, change font size.
Also test `vim`, `htop` and `tmux` without affecting their screen state.
