<p align="center">
  <img src="assets/nia-icon.png" alt="nia_ icon" width="144" />
</p>

# nia_

**Your terminal. Your memory. Everywhere.**

[Español](README.es.md) · [Source code / GitHub](https://github.com/vicktor/nia_) · [License (MPL-2.0)](LICENSE) · [Contributing](CONTRIBUTING.md)

nia_ is an **experimental native terminal for macOS** combining SwiftUI/AppKit chrome with a Metal rendering view and a Rust-based terminal/session core. It is designed for developers who want persistent, individually named shells, a low-overhead UI, and optional AI assistance.

> **Development preview, not production-hardened.** Features such as remote sessions, ANSI reflow, and history restoration are still being validated. Back up your data before upgrading. No claims of audited security or measured resource savings are made.

## Languages and session exit confirmation (v0.7.1)

- nia_ is localized into **English and Spanish**, including menus, Settings, AI, model status, errors, and context actions.
- Open **Settings → General → Language** to choose **Automatic (macOS)**, **English**, or **Spanish**. The choice is saved and does not change session IDs or histories.
- **Ask before closing a session with exit** is enabled by default. When the local interactive Zsh prompt receives the exact command `exit` or `logout`, it pauses and asks for confirmation **before executing anything**.
- Cancel leaves the shell running. Confirm sends the approved exit and removes the tab after the PTY has terminated and its final output is stored; session history remains available for future reopening.
- If a program terminates on its own, nia_ cannot prevent that exit, but removes the completed local shell tab once its output has been saved.
- The guarded `exit` hook currently applies to **local Zsh**, not Bash, Fish, remote SSH shells, or program-specific internal exit commands.

## Multi-window workspaces (experimental)

- **⌘N** (File → New Window) opens an independent native nia_ window.
- Each window has its own ordered tabs, split, focused pane and remembered layout.
- Moving or resizing a window saves its position and size locally. Reopening restores its saved frame; if macOS creates a new scene, it uses the last saved frame. Frames are fitted to the available display when a monitor is disconnected. Full-screen transitions preserve the normal window frame.
- All windows in the same application process share one Rust PTY manager; closing a tab does not delete shell history.
- Open an existing session using the folder-plus button in the sidebar.
- One session can be edited in only one window at a time to avoid conflicting PTY resizes.
- Window layouts are stored in SQLite and included in encrypted backups.
- The original layout is migrated once; new windows start empty.
- macOS scene restoration is not guaranteed to recreate every previously closed window yet.

This workspace coordination is per process: launching separate app processes creates separate terminal managers and session-ownership registries. They do not share the in-memory coordination used by windows opened with **⌘N**.

## Updates, fonts and AI usage

- **nia_ → Check for updates…** reads `vicktor/nia_` GitHub Releases. **Settings → Updates** controls daily checks and the **Stable and prerelease versions** (default) or **Stable versions only** channel. Older versions are never offered.
- GitHub is queried without authentication first. While the repository is private, nia_ can use your existing GitHub CLI (`gh`) session for release metadata and downloads. This fallback is configurable and never copies the token into nia_. When the repository becomes public, updates work without `gh` automatically.
- The architecture-specific ZIP is checked against its SHA-256, bundle identifier, version, macOS compatibility and code signature. **Install and restart…** asks for confirmation: finish local work first. It saves histories and layouts, waits for this instance and all its windows to quit, then replaces the app. The old bundle is retained until the new version starts and restored if Launch Services rejects opening it. Other instances are never forcibly closed. An unwritable application folder offers a link for manual installation. Existing releases are ad-hoc signed; this does not add Apple notarization.
- **Settings → Fonts** offers **JetBrains Mono**, **Fira Code**, **Cascadia Code**, **IBM Plex Mono** and **Source Code Pro**. Downloads come from a pinned revision of the official Google Fonts repository, include the OFL license and are verified against catalog SHA-256 hashes. Fonts are registered only for nia_, without a global installation. The terminal renders individual cells and does not enable multi-character ligatures.
- **Settings → AI → Claude and Codex usage** enables an optional bar showing used weekly quota. Click it for available quota windows, reset dates and token counts with their scope. Missing or expired data is never shown as zero.
- **Codex** uses its local CLI and read-only `app-server` account methods every five minutes. It does not create conversations or generate tokens. Select its executable if detection fails. When available, tokens are an account lifetime total, not the weekly limit.
- **Connect Claude Code** adds an adapter to Claude's `statusLine` setting, preserving the previous command. Restart open Claude sessions to load it. Only numeric metrics are stored locally; transcripts and credentials are not read or copied. **Disconnect** restores the previous status line unless you changed it afterwards. Claude supplies quota after a response on supported plans; token counts belong to the last reporting session. Project settings overriding `statusLine` can prevent this data from reaching nia_.


## Smart links (iTerm2-inspired, lightweight)

In the visible terminal output, **⌘-click** a detected HTTP/HTTPS URL to open it in your default browser. Right-click on a link for **Open link** and **Copy link**. No background URL scanners, networking services, or extra render passes are introduced: only the clicked row is inspected. URLs containing embedded credentials or unsupported schemes are not opened. Some wrapped URLs across multiple terminal lines are not recognized yet.

## Toolbar and shell restoration fixes

- The macOS toolbar is hidden in favor of two **fixed 28 pt** controls in the terminal content header (sidebar toggle and split selector), avoiding oversized controls in light appearance.
- Restarting a local shell starts with a **clean VT screen**. Rendered ANSI history is restored above it, preserving colors and attributes without leaving an old prompt on the live screen.
- The generated Zsh startup configuration disables the standalone `%` end-of-line marker with `PROMPT_EOL_MARK=''`. This does not alter the shell prompt itself.

## Command timeline (iTerm2-inspired, lightweight)

The top toolbar now also includes a **Command timeline** button. Commands that were executed more than once appear only once, showing the latest execution and a **×N** repeat counter. Search results and empty states keep the dialog header, search box and footer fixed. When no command matches a query, the panel shows **No matches** instead of the generic empty-history message.



In a local Zsh session, nia_ records **completed commands** together with their start time, working directory, duration, and exit code. Open the timeline with **⌘⇧H** for the focused session or **right-click a session → Command timeline**. Search by command or directory; copy a command or insert it into the terminal without executing it.

- Uses built-in Zsh `preexec`/`precmd` hooks and an indexed SQLite table. No daemon, model, or periodic terminal text parsing.
- The timeline loads at most the latest **200 commands** when opened; the data remains available in SQLite and encrypted backups after restart.
- Command recording currently tracks **local Zsh only**. **View output** navigates the indexed transcript when a command has a navigation marker.
- Commands may contain credentials. Treat the database and backups as sensitive.

## Session rename and workspace recovery

- Double-click a session name in the sidebar to edit its display title in place. **Return** saves; **Escape** cancels. Right-click → **Rename session** is also available.
- Titles are aliases stored separately in SQLite. Renaming never changes the session's stable ID, PTY, command history, scrollback, remote tmux name, or saved window layout.
- If macOS starts with a fresh scene identifier, the first window now recovers all previously open sessions rather than appearing empty. Every recovered tab gets its shell restored, not just the currently visible split panes.
- Explicitly launched conversations using `claude --resume <id>`, `codex resume <id>`, or `gemini --resume <id>` are remembered while running and re-invoked on shell recovery. Only validated exact resume commands are eligible; arbitrary commands are never replayed.
- Agent session recovery requires the relevant CLI and its own conversation data on this Mac. Existing conversations launched **before** this feature cannot be identified retroactively.

## Command-output navigation (v0.7.4)

Local Zsh now emits an invisible **OSC 133** marker at command start. The streaming history indexer records its exact indexed line in SQLite, independently from the visible PTY. Open the Command Timeline (⌘⇧H) and choose **View output** to jump to the matching transcript page without running the command again. The existing **Copy** and **Insert** actions are unchanged.

- No new daemons or renderer scanning; markers are parsed as ANSI bytes arrive.
- Historical commands recorded before this version have no anchor; **View output** is disabled until a command runs with the updated hooks.
- Navigation uses nia_'s text-indexed historical scrollback; interactive fullscreen TUI rendering cannot be reconstructed pixel-for-pixel from text alone.
- In-memory PTYs, shell state, agent resume and titlebar are unaffected.

## Terminal startup, shell environment and history (v0.7.5)

The initial 30-row × 100-column PTY grid is a temporary fallback. Each visible session now receives its actual pane dimensions, including when SwiftUI reuses the same view for another tab without changing the window size. A size is remembered only after the backend accepts it. The view also checks the reported terminal grid, so reconnecting a PTY under the same session ID cannot keep an obsolete size.

- Pane and terminal fill the available width and height. Geometry is measured after layout, ignoring unattached or zero-sized views; font and display-scale changes revalidate the grid.
- Local Zsh, Bash and Fish start as interactive login shells. Zsh forwards the user's `.zshenv`, `.zprofile`, `.zshrc` and `.zlogin` with their intended `ZDOTDIR`, then installs nia_'s session history, hooks and virtualenv restoration.
- The build script keeps `cargo` already selected in `PATH`. If it is missing there, it checks the existing `${CARGO_HOME:-$HOME/.cargo}/bin` installation. Its error distinguishes a missing path from a missing Rust installation.
- Existing shells keep the environment with which they started. Test the new environment in a fresh session after launching the updated app. Build this first update in a terminal whose toolchain already works.

The **View output** path also preserves CRLF text, repairs older derived indexes from retained raw logs when first needed, and keeps an absolute command position through new output and resizing. Recent commands stay in history mode even when their output fits in one screen.

See [the beta status](STATUS.md) for validation and remaining navigation limits.

## Responsive typing and rendering

The native app now uses one shared output clock at a target interval of 1/60 second, replacing the per-window 120 ms polls. Session metadata updates separately every 500 ms. Visible panes request a compact binary snapshot only when their terminal revision changes; unchanged session lists are not republished to SwiftUI.

An ordered input writer also keeps large pastes and a busy PTY off the UI thread. Its bounded queue accepts each event completely or reports that it cannot be sent yet.

Raw output and its text index are persisted by an ordered background worker. The live parser no longer waits for a file sync before showing echoed input. Queues are bounded and apply backpressure without dropping output. History navigation waits for pending writes, and normal application termination flushes accepted output. Output may be visible before it reaches durable storage: a forced termination or power loss can lose the still-pending tail.

The cursor follows the parser's actual row, including empty rows, and its blink restarts on input or movement. New glyphs use an immutable Metal texture snapshot so the CPU does not overwrite a texture used by an earlier frame.

See [the beta status](STATUS.md) for validation and the remaining macOS visual checks. The refresh interval is a scheduling target, not a measured end-to-end latency guarantee.

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

Wheel/trackpad scrolling keeps terminal colors, attributes, blank rows and Unicode cells. Trackpad motion follows the actual row height, and wheel deltas are not multiplied. The page being read stays fixed during background redraws; typing returns to the live prompt and cancels the preceding trackpad momentum. Resizing preserves the top history row when it remains in the buffer. Fullscreen programs receive their requested mouse-wheel protocol, or arrow keys when they do not enable mouse reporting. Opening another pane no longer schedules a delayed focus change that can override your next click.

Terminal scrolling stops at the configured scrollback limit (1,000–100,000 rows); it no longer switches automatically to the plain-text command index. The complete ANSI log and command index remain on disk, and **View output** still opens the separate textual command-history view. Restoring history parses the saved log once when opening the session; very large logs can delay that opening. Old logs do not record past window sizes, so historical wrapping is reconstructed at the initial grid width.

1. Launch `nia_.app` and create a named session in the sidebar.
2. Change sessions with `⌘1`–`⌘9`; reorder them by dragging. Use `⌘B` to toggle the sidebar.
3. Use the split selector to open a second session, then choose side-by-side or stacked layout. Clicking a terminal pane directs keyboard input to that pane.
4. Open **nia_ → Settings** (`⌘,`) to choose the monospaced font, size, cursor shape, appearance, scrollback and AI provider.
5. Drop a file or folder from Finder into a terminal to insert a shell-escaped path; no Enter is sent.
6. Select text to copy it automatically. Double-click selects a word; triple-click selects a line; Shift-drag selects a rectangle. A native SwiftUI “Copied to clipboard” confirmation appears in the originating pane for two seconds after a successful copy, including ⌘C and **Copy link**. It does not intercept clicks or take keyboard focus; another copy restarts its duration.

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

**Nia Sync now offers encrypted session checkpoints in the development build.** Workspace layouts and live process migration remain pending. The backup handoff described here uses encrypted snapshots, not live database merge. See [README-HANDOFF.md](README-HANDOFF.md).

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

This is an experimental prototype under active development. Known limitations include incomplete terminal reflow for some historical output, unverified behavior for certain full-screen TUIs, incomplete per-session remote synchronization and pending real two-Mac validation of the Nia Sync beta. Please open focused bug reports with reproduction steps and sanitized logs.

## License and contributions

**MPL-2.0** — use for personal projects or commercial products, fork, modify and redistribute. Modified MPL-covered files must remain available under MPL-2.0 **when you distribute them**. It does *not* compel publication of private-only changes or require a public GitHub PR. See [LICENSE](LICENSE), [LICENSE-NOTICE.md](LICENSE-NOTICE.md), and [CONTRIBUTING.md](CONTRIBUTING.md). Third-party components and downloaded model weights have independent terms; see [THIRD_PARTY.md](THIRD_PARTY.md).

Repository: **https://github.com/vicktor/nia_**

## Publishing a GitHub release

Install and authenticate the GitHub CLI (`brew install gh && gh auth login`),
commit your changes and push the branch, then run on a Mac:

```bash
./scripts/release.sh 0.8.0 --prerelease
```

The release script requires a clean, pushed Git worktree and a matching
`Cargo.toml` and bundle version. It builds `dist/nia_.app`, verifies its
code signature and architecture, creates a macOS ZIP using `ditto`, writes a
SHA-256 checksum, tags the commit, and publishes both assets to
`github.com/vicktor/nia_`. Use `--stable` or `--draft` instead if needed.
The development build is ad-hoc signed, **not notarized** by Apple.

## Nia Sync (beta)

This beta shares encrypted session checkpoints through direct Google Drive or an iCloud Drive/synced local folder. Configure **Settings → Sync**, select sessions, then use the cloud button to **Continue here** on another Mac. Local processes, projects and internal agent conversations are not transferred. [Setup, limits and validation](README-SYNC.md#english).

## Multiline editing

**Shift+Return** (including keypad Enter) inserts a new line without executing in local Zsh. Plain **Return** accepts the entire buffer. nia_ sends a distinct Shift+Return key (`CSI 13;2u`) for compatible terminal applications. Remote SSH shells and other shells need their own binding. The Zsh integration is installed when a session opens in this build; personal shell configuration files are unchanged.

Direct Google Drive uses browser authorization and Keychain tokens, without Drive for desktop. OAuth configuration is included at build time, not requested from each user. [Distribution setup](README-SYNC.md#english).

Release descriptions are optional and can be supplied using `NIA_RELEASE_NOTES_FILE=/path/description.md`. No release-history file is required in the repository.
