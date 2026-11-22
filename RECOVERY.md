# Nia Backup — disaster recovery preview (v0.2.0)

The GUI is renamed **Nia**, executable `nia`; the existing Ember data directory is deliberately **not moved** in this release, to preserve sessions. The backup tool is a second executable `nia-backup`. This version is a CLI recovery foundation, **not yet automatic live multi-Mac synchronization**.

## Why restic?

Restic provides authenticated encryption, snapshots, deduplication and remote backends. No plaintext terminal history is sent to GitHub or cloud storage. The local temporary ZIP is deleted after backup. **Backups contain secrets present in shell history and output.** Keep the recovery password somewhere independent of either Mac.

## Requirements

- macOS, Rust and `brew install restic`.
- A **dedicated restic repository** for Nia, e.g. SFTP or S3. A local folder can be used for the first test, **but it is not disaster recovery if it resides on the same Mac**.
- Repository password in `RESTIC_PASSWORD_COMMAND` (preferred, retrieved from Keychain), or `RESTIC_PASSWORD_FILE` with permissions 0600; it must be recoverable on another computer. Set `RESTIC_REPOSITORY` to the exact same storage destination on each computer. For an S3 remote, configure any required S3 credentials separately.

## One-time setup (local test)

```sh
brew install restic
export RESTIC_REPOSITORY="$HOME/nia-test-repo"  # LOCAL TEST ONLY
# Test only: enter a strong passphrase interactively into a private password file.
mkdir -p "$HOME/.config/nia"
umask 077
read -s 'PASS?Nia backup password: '
printf '%s\n' "$PASS" > "$HOME/.config/nia/restic-password"
unset PASS
export RESTIC_PASSWORD_FILE="$HOME/.config/nia/restic-password"
cargo run --release --bin nia-backup -- init
cargo run --release --bin nia-backup -- backup
cargo run --release --bin nia-backup -- snapshots
cargo run --release --bin nia-backup -- check
```

For REAL disaster recovery, configure `RESTIC_REPOSITORY` to an external SFTP/S3 destination before `init`. Do **not** put a password in source code, Git or a shell history. For unattended operation, Keychain with `RESTIC_PASSWORD_COMMAND` is preferable; keep your independent recovery key.

## Recover to a new Mac

1. Install Nia and restic but **do not launch Nia yet**.
2. Configure identical repository URL, authentication and encryption password.
3. Run:

```sh
cargo run --release --bin nia-backup -- snapshots
cargo run --release --bin nia-backup -- restore "$HOME/nia-restored"
```

4. The tool validates paths, recovery format and SQLite integrity, then writes files to `~/nia-restored/state` **without overwriting live data**.
5. With Nia closed and a separate copy of anything already in the destination, move **the contents of** `~/nia-restored/state/` into `~/Library/Application Support/ember-terminal/`. The directory name is intentionally legacy until a future dedicated migration. Do not copy SQLite `-wal`/`-shm` files from elsewhere.
6. Launch Nia. It restores metadata, history and shell configuration. If project directories are not installed on the new Mac, the shell will start in the home directory. Running processes, installed venvs and SSH connections do not magically transfer.

## Limitations

- No unattended schedule, in-app preferences, synchronization engine or merge of competing Mac histories yet.
- Backup snapshots SQLite consistently using `VACUUM INTO`, but the raw PTY logs may change concurrently during copying; a future append-only chunk journal will make a multi-file atomic recovery point.
- Uses a temporary plaintext ZIP on the local disk before restic encrypts it. The temporary file is removed, but disk forensics and backups may retain traces. Future release should stream into encryption without staging plaintext.
- Do not use the same remote repository simultaneously as a bidirectional sync database. This is **backup**, not sync.
- Do not treat backup success as proof of recoverability until you have tested restoration to an empty directory, preferably on another Mac.
