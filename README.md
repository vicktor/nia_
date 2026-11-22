# nia_

**Your terminal. Your memory. Everywhere.**

[Español](README.es.md) · [Source code / GitHub](https://github.com/vicktor/nia_) · [License (MPL-2.0)](LICENSE) · [Contributing](CONTRIBUTING.md)

nia_ is an **experimental native terminal for macOS** combining SwiftUI/AppKit chrome with a Metal rendering view and a Rust-based terminal/session core. It is designed for developers who want persistent, individually named shells, a low-overhead UI, and optional AI assistance.

> **Development preview, not production-hardened.** Features such as remote sessions, ANSI reflow, and history restoration are still being validated. Back up your data before upgrading. No claims of audited security or measured resource savings are made.

## Highlights

| Area | Current capabilities | Important limits |
| --- | --- | --- |
| Native UI | SwiftUI sidebar, menu, Settings, light/dark appearance | macOS 14+ |
| Terminal | Rust PTY, VT interpretation, Metal grid renderer, color, Unicode, adjustable monospaced font/cursor/opacity | Some interactive TUI behaviors and reflow remain experimental |
| Sessions | Named persistent tabs, reordering, colors, independent shell history, restoration, `⌘1`–`⌘9` | A Mac reboot cannot restore the memory of killed processes |
| Split | Side-by-side / stacked terminals, separate input and PTY size, remembered layout | Test restoration after upgrades |
| History | On-disk ANSI output plus SQLite index; scrollback settings, paging | Historical text index is not a pixel-perfect TUI replay |
| Input | Selection copies, `⌘C`/`⌘V`, word/line/rectangular selection, Finder file drops, double-Escape line clear | Double-Escape uses common Emacs shell bindings; shell modes vary |
| AI | `?` prompts in local Zsh, optional local and hosted providers, internal GGUF model, editable proposals and restricted auto-execution | Model output can be wrong; automatic execution is allowlist-based, not a security sandbox |
| Remote | SSH + tmux reconnect for shells running on another Mac | Not full workspace sync; both endpoints must be trusted |
| Backup | Encrypted restic snapshots, CLI recovery and experimental handoff | Configure a repository and test restore separately |

## Requirements

- macOS 14 or newer, preferably an Apple Silicon Mac with Metal support.
- Xcode Command Line Tools (including `swiftc`, `clang`, `sips`, and `iconutil`).
- [Rust](https://rustup.rs/) with Cargo.
- Git and CMake for building the optional embedded `llama-server` helper (`brew install cmake`). The native build currently compiles this helper, so it requires those tools even if you do not select Internal AI.
- Internet access for source dependencies and, optionally, for downloading a GGUF model.
- Optional: `restic` (`brew install restic`) for backups and `tmux` on remote hosts.

## Build and launch

```bash
# From the repository root
./scripts/build-native-macos.sh
open dist/nia_.app
```

The build script compiles the Rust core, optional local inference helper, and SwiftUI app. The output is **`dist/nia_.app`**. It builds into a staging directory and only publishes the bundle after successful signing/verification. Development builds use an ad-hoc signature; notarization for wider distribution is not provided.

The executable inside the bundle is `nia` (`nia_.app/Contents/MacOS/nia`). To install a command-line shortcut explicitly:

```bash
mkdir -p "$HOME/.local/bin"
ln -sf "$(pwd)/dist/nia_.app/Contents/MacOS/nia" "$HOME/.local/bin/nia"
```

The shortcut is to the GUI binary; it does not provide a separate terminal management CLI. Ensure `$HOME/.local/bin` is on your `PATH` if you intend to invoke it by name.

### Backups and recovery CLI

```bash
brew install restic
export RESTIC_REPOSITORY="$HOME/nia-test-repo"   # local test only
# Configure RESTIC_PASSWORD_FILE or RESTIC_PASSWORD_COMMAND securely.
cargo run --release --bin nia-backup -- init
cargo run --release --bin nia-backup -- backup
cargo run --release --bin nia-backup -- snapshots
cargo run --release --bin nia-backup -- check
```

For a real disaster recovery plan, use external SFTP/S3 storage and keep your recovery secret off both Macs. Test a restore on a clean destination. See [RECOVERY.md](RECOVERY.md).

## Getting started

1. Launch `nia_.app` and create a named session in the sidebar.
2. Change sessions with `⌘1`–`⌘9`; reorder them by dragging. Use `⌘B` to toggle the sidebar.
3. Use the split selector to open a second session, then choose side-by-side or stacked layout. Clicking a terminal pane directs keyboard input to that pane.
4. Open **nia_ → Settings** (`⌘,`) to choose the monospaced font, size, cursor shape, appearance, scrollback and AI provider.
5. Drop a file or folder from Finder into a terminal to insert a shell-escaped path; no Enter is sent.
6. Select text to copy it automatically. Double-click selects a word; triple-click selects a line; Shift-drag selects a rectangle.

### AI commands

In a **local Zsh** terminal, start the line with `?` and press Enter:

```text
?find files larger than 1 GB in the current directory
```

nia_ asks the selected model for a shell command. Simple commands may run automatically **only when the automatic-action option is enabled and an independent conservative validator permits them**. More complex or potentially destructive operations require review. A generated command should never be treated as verified solely because a model produced it.

AI options include an internal small command-oriented model run through `llama.cpp` on demand, an OpenAI-compatible **Local** endpoint (such as vLLM, Ollama or LM Studio), and external OpenAI/Anthropic/Gemini/OpenRouter connectors using provider keys in macOS Keychain. The internal small model is suitable only for simple commands, not multi-step system administration. The initial `?` interception is limited to local Zsh, not Bash/Fish or remote shells.

See [README-NIA-AI.md](README-NIA-AI.md) and [README-INTERNAL-AI.md](README-INTERNAL-AI.md) for details; older feature-specific notes may refer to historical versions.

### Remote shells

Enable Remote Login on the host Mac, set up a verified SSH key and install `tmux` there. In nia_ choose a remote session and an SSH alias. The actual processes, filesystem and resources remain on the host; SSH carries an encrypted, authenticated terminal stream. Closing the client does not normally stop a tmux session, but shutting down the host terminates running processes. See [README-REMOTE.md](README-REMOTE.md).

**Nia Sync (automatic bidirectional workspace syncing) is not yet implemented.** The existing handoff uses encrypted backup snapshots, not live database merge. See [README-HANDOFF.md](README-HANDOFF.md).

## Architecture

```text
native/Sources/           SwiftUI/AppKit and MTKView, AI UX
native/include/           Rust ↔ Swift C bridge
src/lib.rs                Rust FFI/session management
src/terminal.rs           PTY, VT parser, session lifecycle
src/storage.rs            SQLite metadata and persistent state
src/history.rs            Paginated historical output
src/bin/nia-backup.rs     restic backup and restore CLI
scripts/build-native-macos.sh   Native bundle build
assets/                   App icon
```

The app currently retains the historical `~/Library/Application Support/ember-terminal/` data directory **intentionally** to preserve existing sessions. Do **not** delete or rename it as part of the app rebranding. The macOS bundle identifier remains `dev.nia.terminal` for compatibility with existing application preferences and credentials.

## Performance and privacy

The renderer is Metal-backed and the terminal/session logic is written in Rust. The internal LLM is optional and served on demand; it consumes extra memory while active. No benchmarked RAM/CPU guarantees are claimed. Use Activity Monitor/Instruments to measure the actual app, child shells, graphics resources and inference subprocess separately.

Terminal logs and backups can contain secrets. Review output capture and secure restic storage. External model providers receive the prompts you submit to them; the internal model runs locally (apart from its initial download). No model-generated shell command is guaranteed safe; the allowlist is a defensive layer, not a sandbox.

## Project status

This is an experimental prototype under active development. Known limitations include incomplete terminal reflow for some historical output, unverified behavior for certain full-screen TUIs, incomplete per-session remote synchronization and absence of automatic bidirectional Nia Sync. Please open focused bug reports with reproduction steps and sanitized logs.

## License and contributions

**MPL-2.0** — use for personal projects or commercial products, fork, modify and redistribute. Modified MPL-covered files must remain available under MPL-2.0 **when you distribute them**. It does *not* compel publication of private-only changes or require a public GitHub PR. See [LICENSE](LICENSE), [LICENSE-NOTICE.md](LICENSE-NOTICE.md), and [CONTRIBUTING.md](CONTRIBUTING.md). Third-party components and downloaded model weights have independent terms; see [THIRD_PARTY.md](THIRD_PARTY.md).

Repository: **https://github.com/vicktor/nia_**
