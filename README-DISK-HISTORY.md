# Nia v0.4.3 — disk-indexed history (experimental)

## What is implemented

- A per-session SQLite `history_lines(session_id,line_no,text)` table with a compound index.
- Incremental, bounded-memory output indexing; original ANSI `.bin` logs are retained.
- When live `vt100` scrollback reaches its cap, the wheel can enter paged text-only history.
- Only the requested visible rows are materialized from SQLite; the index is not loaded into a Rust Vec.
- Existing session database and archived logs remain in place.

## Important limits

- Only new output after installing this version is indexed; historical `.bin` files are not backfilled.
- Deep historical pages contain text, **not full terminal screen semantics or ANSI colors**. Interactive TUIs and carriage returns may not reproduce faithfully.
- The transition from VT scrollback to text pages may not align perfectly around wrapped lines and TUI redraws.
- The original replay limit (32 MiB) remains. Deep history browsing does not eliminate the need for future checkpoint-based restoration.
- The SQLite index consumes disk space and may include credentials or private data printed by shell commands; protect it with owner-only file permissions and encrypted backup.
- A power loss between writing the raw log and indexing it may leave a small unindexed tail; a re-index operation is not yet implemented.
- Changing the in-memory line limit still requires opening a new PTY/session.

## Testing on macOS

```bash
./scripts/build-native-macos.sh
open dist/Nia.app
```

In a session try `seq 1 15000` with a low in-memory scrollback setting, then scroll upward beyond the in-memory boundary. Close and reopen the app and verify that history metadata persists. Test commands on a disposable session before using with sensitive output. Also test with `cargo test`.

## Next steps

- Proper VT checkpoints for exact colors and screen state after restart.
- Crash-safe index reconciliation and migration/backfill of old logs.
- More efficient immutable compressed history blocks and source-text search.
- Backups with retention and encryption validated on another Mac.
