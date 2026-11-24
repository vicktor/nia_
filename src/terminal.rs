// SPDX-License-Identifier: MPL-2.0
use anyhow::{Context, Result};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::{fs::{self, File}, io::{Read, Seek, SeekFrom}, num::NonZeroU16, path::{Path, PathBuf}, sync::mpsc::{self, Receiver}, thread};
#[cfg(test)]
use std::io::Write;
use crate::{storage::{SessionRecord, Store}, history::HistoryIndexer, pty_input::PtyInput};

/// Encode wheel events only for a program that owns mouse handling or the
/// alternate screen. Normal shell scrollback never receives synthetic input.
pub(crate) fn wheel_input(screen: &vt100::Screen, delta: i32, row: u16, col: u16) -> Option<Vec<u8>> {
    let count = delta.unsigned_abs().min(256) as usize;
    let mouse = screen.mouse_protocol_mode() != vt100::MouseProtocolMode::None;
    if !mouse && !screen.alternate_screen() { return None; }
    let sequence = if mouse {
        let button = if delta > 0 { 64_u16 } else { 65 };
        let (rows, cols) = screen.size();
        let x = col.min(cols.get() - 1).saturating_add(1);
        let y = row.min(rows.get() - 1).saturating_add(1);
        match screen.mouse_protocol_encoding() {
            vt100::MouseProtocolEncoding::Sgr => format!("\x1b[<{button};{x};{y}M").into_bytes(),
            vt100::MouseProtocolEncoding::Default => vec![27, b'[', b'M', (button + 32) as u8,
                (x.min(223) + 32) as u8, (y.min(223) + 32) as u8],
            vt100::MouseProtocolEncoding::Utf8 => {
                let mut bytes = b"\x1b[M".to_vec();
                for value in [button + 32, x.min(2015) + 32, y.min(2015) + 32] {
                    let mut buffer = [0; 4];
                    bytes.extend_from_slice(char::from_u32(u32::from(value)).unwrap().encode_utf8(&mut buffer).as_bytes());
                }
                bytes
            }
        }
    } else {
        vec![27, if screen.application_cursor() { b'O' } else { b'[' }, if delta > 0 { b'A' } else { b'B' }]
    };
    Some(sequence.repeat(count))
}

pub struct LiveTerminal {
    pub parser: vt100::Parser,
    history_view: Option<vt100::Parser>,
    pub input: PtyInput,
    pub master: Box<dyn MasterPty + Send>,
    pub rx: Receiver<Vec<u8>>,
    pub remote: bool,
    pub history_indexer: HistoryIndexer,
    state_path: PathBuf,
    ai_request_path: Option<PathBuf>,
    exit_request_path: Option<PathBuf>,
    exit_approval_path: Option<PathBuf>,
    pub exit_observed_polls: u8,
    marks_file: Option<File>,
    marks_offset: u64,
    marks_buffer: Vec<u8>,
    pending_mark: Option<(f64, String, String)>,
    agent_resume_path: Option<PathBuf>,
    pub _child: Box<dyn portable_pty::Child + Send + Sync>,
}

impl LiveTerminal {
    /// Keep the page being read independent of subsequent TUI redraws. Only
    /// the visible page is copied, not the parser's entire scrollback buffer.
    pub fn freeze_history_view(&mut self) {
        let screen = self.parser.screen();
        self.history_view = if screen.scrollback() > 0 {
            let (rows, cols) = screen.size();
            let mut page = vt100::Parser::new(rows, cols, 0);
            page.process(screen.contents_formatted().as_bytes());
            page.process(b"\x1b[?25l");
            Some(page)
        } else {
            None
        };
    }

    pub fn display_screen(&self) -> &vt100::Screen {
        self.history_view.as_ref().unwrap_or(&self.parser).screen()
    }

    pub fn return_to_live(&mut self) -> bool {
        let changed = self.history_view.is_some() || self.parser.screen().scrollback() > 0;
        self.parser.screen_mut().set_scrollback(0);
        self.history_view = None;
        changed
    }

    /// Restore only rendered history, never terminal modes, a stale live
    /// prompt, or control sequences from a previous process into the new PTY.
    pub fn restore_scrollback(&mut self, store: &Store, id: &str) -> Result<()> {
        let (rows, cols) = self.parser.screen().size();
        let mut old = vt100::Parser::new(rows, cols, self.parser.screen().scrollback_capacity());
        store.replay_stream(id, |bytes| old.process(bytes))?;
        // An interrupted fullscreen program must not become the new shell's
        // alternate screen. Its normal-screen scrollback is still available.
        old.process(b"\x1b[?1049l");
        let mut rendered = String::new();
        old.screen().write_contents_formatted_basic(
            &mut rendered,
            vt100::capture::BasicFormattedCaptureRange::Full(&mut Default::default()),
        )?;
        let rendered = rendered.trim_end_matches('\n');
        if rendered.is_empty() {
            return Ok(());
        }
        // Basic capture contains text and SGR only. Move its final row into
        // scrollback and leave an entirely empty viewport for the new shell.
        self.parser.process(rendered.replace('\n', "\r\n").as_bytes());
        self.parser.process(b"\x1b[0m\r");
        for _ in 0..rows.get() {
            self.parser.process(b"\n");
        }
        self.parser.process(b"\x1b[2J\x1b[H\x1b[?25h");
        Ok(())
    }

    pub fn spawn(record: SessionRecord, rows: u16, cols: u16, scrollback_lines: usize, remote_host: Option<&str>, remote_origin: Option<&str>) -> Result<Self> {
        let rows = rows.max(1);
        let cols = cols.max(1);
        let pair = native_pty_system().openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })?;
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_owned());
        // Remote shells are attached to tmux on the destination, never run locally.
        // SSH performs authenticated, encrypted transport with strict host key verification.
        let mut command = if let Some(host) = remote_host {
            let mut c = CommandBuilder::new("/usr/bin/ssh");
            for arg in ["-tt", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                        "-o", "ConnectTimeout=10", "--", host] {
                c.arg(arg);
            }
            // A fixed PATH works for Apple Silicon (/opt/homebrew) and Intel
            // (/usr/local) even when sshd launches a non-login shell.
            // The only interpolated value is a hex-encoded session identifier.
            c.arg(format!("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH exec tmux new-session -A -s {}", remote_tmux_name(remote_origin.unwrap_or(&record.id))));
            c
        } else {
            let mut c = CommandBuilder::new(shell.as_str());
            // GUI apps do not inherit a terminal's login environment. Let the
            // user's shell load its profiles (Rust, Homebrew, language tools).
            for arg in local_shell_args(&shell) {
                c.arg(*arg);
            }
            c
        };
        // Advertise ANSI 256-color and truecolor support to local programs.
        // Without an explicit TERM, a GUI-launched app may inherit "dumb"
        // or an unrelated terminal definition; interactive TUIs then disable
        // their color output before it ever reaches the Metal renderer.
        // The remote SSH path keeps its own terminal negotiation.
        if remote_host.is_none() {
            command.env("TERM", "xterm-256color");
            command.env("COLORTERM", "truecolor");
        }
        // Zsh reads its history at shell startup. Install a per-session startup
        // directory that sources the user's configuration, then overrides HISTFILE.
        if remote_host.is_some() {
            // Never send local ZDOTDIR, HISTFILE, or VIRTUAL_ENV to a remote machine.
        } else if shell.ends_with("/zsh") || shell == "zsh" {
            let zdotdir = prepare_zsh_history(&record.id)?;
            command.env("ZDOTDIR", zdotdir.to_string_lossy().to_string());
            if let Some(venv) = &record.venv {
                if Path::new(venv).join("bin/activate").is_file() {
                    command.env("EMBER_RESTORE_VENV", venv);
                }
            }
        } else {
            let history_file = session_base(&record.id)?.join("shell_history");
            command.env("HISTFILE", history_file.to_string_lossy().to_string());
        }
        if remote_host.is_none() && std::path::Path::new(&record.cwd).is_dir() { command.cwd(&record.cwd); }
        // Only restore paths to already-existing environments, never replay shell commands.
        if let Some(venv) = &record.venv {
            if remote_host.is_none() && std::path::Path::new(venv).join("bin/python").is_file() {
                command.env("VIRTUAL_ENV", venv);
                let current_path = std::env::var("PATH").unwrap_or_default();
                command.env("PATH", format!("{venv}/bin:{current_path}"));
            }
        }
        let child = pair.slave.spawn_command(command)?;
        let reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let input = PtyInput::for_pty(pair.master.as_ref(), writer)?;
        let mut reader = input.reader(reader);
        // A slow disk or a temporarily busy UI must apply backpressure instead
        // of retaining an unbounded terminal transcript in memory.
        let (tx, rx) = mpsc::sync_channel(64);
        thread::Builder::new().name(format!("pty-{}",record.id)).spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => if tx.send(buf[..n].to_vec()).is_err() { break; },
                }
            }
        }).context("start PTY reader")?;
        let state_path = session_base(&record.id)?.join("state");
        let ai_request_path = if remote_host.is_none() && (shell.ends_with("/zsh") || shell == "zsh") {
            Some(session_base(&record.id)?.join("ai-request"))
        } else { None };
        let exit_request_path = ai_request_path.as_ref().map(|_| session_base(&record.id).map(|p| p.join("exit-request"))).transpose()?;
        let exit_approval_path = ai_request_path.as_ref().map(|_| session_base(&record.id).map(|p| p.join("exit-approved"))).transpose()?;
        // Only local Zsh uses the zero-extra-process command metadata hooks.
        // Keep one read handle open for the PTY lifetime to avoid repeated
        // open/close operations while polling many sessions.
        let marks_file = if ai_request_path.is_some() {
            let path = session_base(&record.id)?.join("command-marks");
            let file = fs::OpenOptions::new().read(true).write(true)
                .create(true).truncate(true).open(path)?;
            #[cfg(unix)] {
                use std::os::unix::fs::PermissionsExt;
                file.set_permissions(fs::Permissions::from_mode(0o600))?;
            }
            Some(file)
        } else { None };
        let agent_resume_path = if ai_request_path.is_some() {
            Some(session_base(&record.id)?.join("agent-resume"))
        } else { None };
        let saved_agent = agent_resume_path.as_ref().and_then(|path|
            fs::read_to_string(path).ok()).and_then(|line| validated_agent_resume(line.trim()));
        let mut terminal = Self { state_path, ai_request_path, exit_request_path, exit_approval_path, exit_observed_polls: 0,
            marks_file, marks_offset: 0, marks_buffer: Vec::new(), pending_mark: None, agent_resume_path,
            history_indexer: HistoryIndexer::default(), parser: vt100::Parser::new(NonZeroU16::new(rows).unwrap(), NonZeroU16::new(cols).unwrap(), scrollback_lines), history_view: None,
            input, master: pair.master, rx, remote: remote_host.is_some(), _child: child };
        // Only a previously observed explicit resume command is replayed.
        // Never replay arbitrary shell history or unvalidated input.
        if let Some(command) = saved_agent {
            terminal.send(format!("{command}\r").as_bytes())?;
        }
        Ok(terminal)
    }

    /// Read only new appended metadata, capped to 64 KiB per poll. Hooks use
    /// Zsh builtins and write NUL-framed values to avoid delimiter injections.
    /// No command data is parsed during terminal drawing.
    pub fn take_command_marks(&mut self) -> Result<Vec<(f64, i64, i64, String, String)>> {
        let Some(file) = self.marks_file.as_mut() else { return Ok(Vec::new()) };
        let len = file.metadata()?.len();
        if len < self.marks_offset {
            self.marks_offset = 0;
            self.marks_buffer.clear();
            self.pending_mark = None;
        }
        file.seek(SeekFrom::Start(self.marks_offset))?;
        let mut buf = vec![0u8; 65536.min(len.saturating_sub(self.marks_offset) as usize)];
        let count = file.read(&mut buf)?;
        self.marks_offset += count as u64;
        self.marks_buffer.extend_from_slice(&buf[..count]);
        // A single command is limited to 8 KiB of metadata. If malformed or
        // partial payload grows beyond this, discard it safely.
        if self.marks_buffer.len() > 131072 {
            self.marks_buffer.clear();
            self.pending_mark = None;
        }
        let mut completed = Vec::new();
        let mut consumed = 0;
        loop {
            let body = &self.marks_buffer[consumed..];
            let kind = match body.first() { Some(&b'S') => b'S', Some(&b'E') => b'E', _ => break };
            if body.get(1) != Some(&0) { break }
            let needed = if kind == b'S' { 3 } else { 2 };
            let mut cursor = 2;
            let mut fields = Vec::with_capacity(needed);
            for _ in 0..needed {
                let Some(end) = body[cursor..].iter().position(|b| *b == 0) else { break };
                let value = &body[cursor..cursor + end];
                fields.push(String::from_utf8_lossy(value).into_owned());
                cursor += end + 1;
            }
            if fields.len() != needed { break }
            if kind == b'S' {
                if let Ok(started) = fields[0].parse::<f64>() {
                    if started.is_finite() && fields[1].len() <= 4096 && fields[2].len() <= 8192 {
                        // Remember the explicit resume command while the CLI is
                        // still running, not only once it returns to the prompt.
                        if let Some(path) = &self.agent_resume_path {
                            if let Some(command) = validated_agent_resume(&fields[2]) {
                                let temp = path.with_extension("tmp");
                                fs::write(&temp, command)?;
                                #[cfg(unix)] {
                                    use std::os::unix::fs::PermissionsExt;
                                    fs::set_permissions(&temp, fs::Permissions::from_mode(0o600))?;
                                }
                                fs::rename(temp, path)?;
                            } else {
                                let _ = fs::remove_file(path);
                            }
                        }
                        self.pending_mark = Some((started, fields[1].clone(), fields[2].clone()));
                    }
                }
            } else if let Some((start, cwd, command)) = self.pending_mark.take() {
                // Once the agent has exited, restarting it would be wrong.
                if let Some(path) = &self.agent_resume_path {
                    let _ = fs::remove_file(path);
                }
                if let (Ok(end), Ok(status)) = (fields[0].parse::<f64>(), fields[1].parse::<i64>()) {
                    if end.is_finite() && end >= start && end - start < 86400.0 * 7.0 {
                        let duration_ms = ((end - start) * 1000.0).round() as i64;
                        completed.push((start, duration_ms, status, cwd, command));
                    }
                }
            }
            consumed += cursor;
            if consumed == self.marks_buffer.len() { break }
        }
        if consumed > 0 { self.marks_buffer.drain(..consumed); }
        Ok(completed)
    }

    /// Zsh's accept-line widget writes an owner-only atomic request. Remove it
    /// immediately: natural-language queries must never enter shell history.
    pub fn take_ai_request(&self) -> Result<Option<String>> {
        let Some(path) = &self.ai_request_path else { return Ok(None) };
        let metadata = match fs::metadata(path) {
            Ok(value) => value,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        // Hard limit; do not ingest arbitrarily large files from the shell.
        if metadata.len() > 8192 { let _ = fs::remove_file(path); return Ok(None) }
        let content = fs::read_to_string(path);
        let _ = fs::remove_file(path);
        let content = content?;
        let question = content.trim().to_owned();
        if question.is_empty() { return Ok(None) }
        Ok(Some(question))
    }

    /// A local Zsh requested a protected exit without executing it yet.
    pub fn take_exit_request(&self) -> Result<bool> {
        let Some(path) = &self.exit_request_path else { return Ok(false) };
        match fs::remove_file(path) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.into()),
        }
    }

    /// Permit exactly one exit from the normal ZLE accept-line widget.
    pub fn approve_exit(&mut self) -> Result<()> {
        let approval = self.exit_approval_path.clone()
            .context("Exit interception is only supported in local Zsh")?;
        fs::write(&approval, b"approved")?;
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&approval, fs::Permissions::from_mode(0o600))?;
        }
        if let Err(e) = self.send(b"exit\r") {
            let _ = fs::remove_file(&approval);
            return Err(e);
        }
        Ok(())
    }

    pub fn snapshot_state(&self) -> Result<Option<(String, Option<String>)>> {
        let state = match fs::read_to_string(&self.state_path) {
            Ok(s) => s,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let Some((cwd, venv)) = state.split_once('\n') else { return Ok(None); };
        if cwd.is_empty() || !Path::new(cwd).is_dir() { return Ok(None); }
        let venv = venv.trim_end_matches('\n');
        let venv = if !venv.is_empty() && Path::new(venv).join("bin/python").is_file() {
            Some(venv.to_owned())
        } else { None };
        Ok(Some((cwd.to_owned(), venv)))
    }

    pub fn send(&mut self, bytes: &[u8]) -> Result<()> { self.input.send(bytes) }
    pub fn input_error(&self) -> Option<String> { self.input.error() }
    pub fn resize(&mut self, rows: u16, cols: u16) -> Result<()> {
        let rows = rows.max(1);
        let cols = cols.max(1);
        self.master.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })?;
        let previous_offset = self.parser.screen().scrollback();
        let previous_length = self.parser.screen().scrollback_len();
        self.parser.set_size(NonZeroU16::new(rows).unwrap(), NonZeroU16::new(cols).unwrap());
        if previous_offset > 0 {
            // VT resize moves rows between the viewport and scrollback and
            // resets the offset. Anchor the same top row across that transfer.
            let next_length = self.parser.screen().scrollback_len();
            let offset = previous_offset.saturating_add(next_length).saturating_sub(previous_length);
            self.parser.screen_mut().set_scrollback(offset);
            self.freeze_history_view();
        }
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn request_paths_for_tests(&mut self, ai: PathBuf, exit: PathBuf) {
        self.ai_request_path = Some(ai);
        self.exit_request_path = Some(exit);
    }

    #[cfg(test)]
    pub(crate) fn for_history_tests(rows: u16, cols: u16) -> Result<Self> {
        let pair = native_pty_system().openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        let child = pair.slave.spawn_command(CommandBuilder::new("/bin/cat"))?;
        let input = PtyInput::for_pty(pair.master.as_ref(), pair.master.take_writer()?)?;
        let (_tx, rx) = mpsc::channel();
        Ok(Self {
            history_view: None,
            parser: vt100::Parser::new(
                NonZeroU16::new(rows).unwrap(),
                NonZeroU16::new(cols).unwrap(),
                100,
            ),
            input,
            master: pair.master,
            rx,
            remote: false,
            history_indexer: HistoryIndexer::default(),
            state_path: PathBuf::new(),
            ai_request_path: None,
            exit_request_path: None,
            exit_approval_path: None,
            exit_observed_polls: 0,
            marks_file: None,
            marks_offset: 0,
            marks_buffer: Vec::new(),
            pending_mark: None,
            agent_resume_path: None,
            _child: child,
        })
    }
}

impl Drop for LiveTerminal {
    fn drop(&mut self) {
        self.input.cancel();
        // Input/output workers observe cancellation within their bounded poll
        // wait. Terminate only the local shell/SSH child as this session closes.
        // Remote tmux is independent of that SSH client and remains running.
        if !matches!(self._child.try_wait(), Ok(Some(_))) {
            let _ = self._child.kill();
        }
    }
}

/// Fail-closed recognition of commands the user explicitly ran to resume
/// a known agent conversation. An arbitrary command is NEVER re-executed.
fn validated_agent_resume(source: &str) -> Option<String> {
    let parts: Vec<&str> = source.split_ascii_whitespace().collect();
    let (provider, id) = match parts.as_slice() {
        ["claude", "--resume", id] => ("claude --resume", *id),
        ["codex", "resume", id] => ("codex resume", *id),
        ["gemini", "--resume", id] => ("gemini --resume", *id),
        _ => return None,
    };
    if !(8..=128).contains(&id.len()) ||
        !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
        return None;
    }
    Some(format!("{provider} {id}"))
}

// Stable and filesystem-safe per-session directory. Session IDs can contain unicode.
fn session_base(id: &str) -> Result<PathBuf> {
    let base = dirs::data_local_dir().context("no local data directory")?
        .join("ember-terminal").join("shells");
    let mut hex = String::with_capacity(id.len() * 2);
    for b in id.bytes() { hex.push_str(&format!("{b:02x}")); }
    let path = base.join(hex);
    fs::create_dir_all(&path)?;
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(path)
}

fn remote_tmux_name(id: &str) -> String {
    // Hex encoding creates a stable, shell-safe tmux name without interpolating user input.
    let mut name = String::from("nia-");
    for b in id.as_bytes() { use std::fmt::Write as _; let _ = write!(&mut name, "{b:02x}"); }
    name
}

fn zsh_quote(path: &Path) -> String {
    // Shell-quote paths in generated startup snippets, never interpolate raw IDs.
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}

fn local_shell_args(shell: &str) -> &'static [&'static str] {
    match Path::new(shell).file_name().and_then(|name| name.to_str()) {
        Some("zsh" | "bash" | "fish") => &["-l", "-i"],
        // Preserve compatibility with custom shells whose flags are unknown.
        _ => &[],
    }
}

fn prepare_zsh_history(id: &str) -> Result<PathBuf> {
    let base = session_base(id)?;
    let original = std::env::var_os("ZDOTDIR").map(PathBuf::from);
    write_zsh_startup(&base, original.as_deref())?;
    Ok(base)
}

/// Forward each Zsh startup phase with the user's ZDOTDIR, not the integration
/// directory. A .zshenv/.zprofile can legitimately redirect later startup files.
/// After startup restore the user's value so child shells cannot recursively
/// source Nia's wrappers. Write every wrapper even when a user file is absent:
/// a removed profile must not leave a stale absolute source path behind.
fn write_zsh_startup(base: &Path, original: Option<&Path>) -> Result<()> {
    const BANNER: &str = "# Generated by Nia;";
    // Older versions exported the wrapper directory into every child process.
    // A Nia launched from such a shell should restart at the user's .zshenv.
    let original = original.filter(|path| {
        *path != base
            && !fs::read_to_string(path.join(".zshrc"))
                .map(|text| text.starts_with(BANNER))
                .unwrap_or(false)
    });
    let initial = match original {
        Some(path) => format!(
            "typeset -g _nia_user_zdotdir={}\ntypeset -gi _nia_user_zdotdir_set=1\n",
            zsh_quote(path)
        ),
        None => "typeset -g _nia_user_zdotdir=''\ntypeset -gi _nia_user_zdotdir_set=0\n".to_owned(),
    };
    let restore = "if (( _nia_user_zdotdir_set )); then\n  export ZDOTDIR=\"$_nia_user_zdotdir\"\nelse\n  unset ZDOTDIR\nfi\n";
    let remember = "_nia_user_zdotdir=${ZDOTDIR-}\n_nia_user_zdotdir_set=${+ZDOTDIR}\n";
    let keep_wrapper = format!("export ZDOTDIR={}\n", zsh_quote(base));
    let integration = format!(
        "builtin source {}\n",
        zsh_quote(&base.join("nia-integration.zsh"))
    );
    let cleanup = "unset _nia_user_zdotdir _nia_user_zdotdir_set\n";
    for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
        let mut content = format!("{BANNER} forward the user's {name}.\n");
        if name == ".zshenv" {
            content.push_str(&initial);
        }
        content.push_str(restore);
        content.push_str(&format!("if [[ -f \"${{ZDOTDIR-$HOME}}/{name}\" ]]; then\n  builtin source \"${{ZDOTDIR-$HOME}}/{name}\"\nfi\n"));
        content.push_str(remember);
        match name {
            ".zshenv" => {
                content.push_str("if [[ -o rcs && ( -o login || -o interactive ) ]]; then\n");
                content.push_str(&keep_wrapper);
                content.push_str("else\n");
                content.push_str(cleanup);
                content.push_str("fi\n");
            }
            ".zprofile" => {
                content.push_str("if [[ -o rcs ]]; then\n");
                content.push_str(&keep_wrapper);
                content.push_str("else\n");
                content.push_str(cleanup);
                content.push_str("fi\n");
            }
            ".zshrc" => {
                content.push_str("if [[ -o rcs && -o login ]]; then\n");
                content.push_str(&keep_wrapper);
                content.push_str("else\n");
                content.push_str(&integration);
                content.push_str(cleanup);
                content.push_str("fi\n");
            }
            _ => {
                content.push_str("if [[ -o interactive ]]; then\n");
                content.push_str(&integration);
                content.push_str("fi\n");
                content.push_str(cleanup);
            }
        }
        fs::write(base.join(name), content)?;
    }
    // A query left by a previous crashed process is not a new request.
    let _ = fs::remove_file(base.join("ai-request"));
    let _ = fs::remove_file(base.join("exit-request"));
    let _ = fs::remove_file(base.join("exit-approved"));
    let history = base.join("shell_history");
    // Create an owner-only history file, also protecting existing installations.
    let _file = fs::OpenOptions::new().create(true).append(true).open(&history)?;
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&history, fs::Permissions::from_mode(0o600))?;
    }
    let content = format!("# Generated by Nia; preserve user's normal Zsh setup.\n\
        HISTFILE={0}\n\
        HISTSIZE=20000\n\
        SAVEHIST=20000\n\
        unsetopt SHARE_HISTORY\n\
        setopt INC_APPEND_HISTORY\n\
        # Suppress Zsh's isolated '%' marker when previous output lacks LF.\n\
        PROMPT_EOL_MARK=''\n\
        # Restore a previously active venv only if it still exists.\n\
        if [[ -n ${{EMBER_RESTORE_VENV:-}} && -f $EMBER_RESTORE_VENV/bin/activate ]]; then\n\
          source $EMBER_RESTORE_VENV/bin/activate\n\
        fi\n\
        # Save current directory and virtualenv after every interactive command.\n\
        function _ember_capture_state() {{\n\
          local tmp={1}.tmp.$$\n\
          ( umask 077; print -r -- \"$PWD\" > \"$tmp\"; print -r -- \"${{VIRTUAL_ENV:-}}\" >> \"$tmp\" )\n\
          command mv -f -- \"$tmp\" {1}\n\
        }}\n\
        autoload -Uz add-zsh-hook\n\
        # Command timeline: built-in Zsh hooks, no subprocess or prompt edits.\n\
        zmodload zsh/datetime 2>/dev/null\n\
        function _nia_mark_start() {{\n\
          local started=$EPOCHREALTIME\n\
          builtin printf 'S\\0%s\\0%s\\0%s\\0' \"$started\" \"$PWD\" \"$1\" >> {5}\n\
          builtin printf '\\033]133;C;%s\\007' \"$started\"\n\
        }}\n\
        function _nia_mark_end() {{\n\
          local exit_status=$?\n\
          builtin printf 'E\\0%s\\0%s\\0' \"$EPOCHREALTIME\" \"$exit_status\" >> {5}\n\
        }}\n\
        add-zsh-hook preexec _nia_mark_start\n\
        # Register the completion hook first: subsequent state hooks may\n\
        # overwrite $? and would corrupt the command's exit status.\n\
        add-zsh-hook precmd _nia_mark_end\n\
        add-zsh-hook precmd _ember_capture_state\n\
        # Nia AI: intercept only a ZLE command line that starts with ?.\n\
        # The question never reaches the shell execution path or HISTFILE.\n\
        function _nia_ai_accept_line() {{\n\
          if [[ $BUFFER == \\?* ]]; then\n\
            local question=${{BUFFER#\\?}}\n\
            if [[ -n ${{question//[[:space:]]/}} ]]; then\n\
              local tmp={2}.tmp.$$\n\
              ( umask 077; print -rn -- \"$question\" > \"$tmp\" )\n\
              command mv -f -- \"$tmp\" {2}\n\
              BUFFER=''\n\
              CURSOR=0\n\
              zle reset-prompt\n\
              return 0\n\
            fi\n\
          fi\n\
          # Intercept only the literal exit/logout line, before the shell sees it.\n\
          # The UI asks for consent and later creates a one-shot approval file.\n\
          if [[ $BUFFER == exit || $BUFFER == logout ]]; then\n\
            if [[ -f {3} ]]; then\n\
              command rm -f -- {3}\n\
              zle .accept-line\n\
              return 0\n\
            fi\n\
            local tmp={4}.tmp.$$\n\
            ( umask 077; print -r -- exit > \"$tmp\" )\n\
            command mv -f -- \"$tmp\" {4}\n\
            BUFFER=''\n\
            CURSOR=0\n\
            zle reset-prompt\n\
            return 0\n\
          fi\n\
          zle .accept-line\n\
        }}\n\
        zle -N accept-line _nia_ai_accept_line\n\
        # Shift+Return inserts a literal line break without accepting the buffer.\n\
        function _nia_insert_newline() {{ LBUFFER+=$'\\n' }}\n\
        zle -N nia-insert-newline _nia_insert_newline\n\
        builtin bindkey -M emacs '^[[13;2u' nia-insert-newline\n\
        builtin bindkey -M viins '^[[13;2u' nia-insert-newline\n\
        builtin bindkey -M vicmd '^[[13;2u' nia-insert-newline\n",
        zsh_quote(&history), zsh_quote(&base.join("state")), zsh_quote(&base.join("ai-request")),
        zsh_quote(&base.join("exit-approved")), zsh_quote(&base.join("exit-request")),
        zsh_quote(&base.join("command-marks")));
    fs::write(base.join("nia-integration.zsh"), content)?;
    Ok(())
}

#[cfg(test)]
mod history_tests {
    use super::*;

    #[test]
    fn wheel_respects_application_mouse_protocol_and_cursor_mode() {
        let mut parser = vt100::Parser::new(NonZeroU16::new(10).unwrap(), NonZeroU16::new(300).unwrap(), 100);
        assert_eq!(wheel_input(parser.screen(), 3, 2, 4), None);
        parser.process(b"\x1b[?1049h");
        assert_eq!(wheel_input(parser.screen(), 2, 2, 4).unwrap(), b"\x1b[A\x1b[A");
        parser.process(b"\x1b[?1h");
        assert_eq!(wheel_input(parser.screen(), -1, 2, 4).unwrap(), b"\x1bOB");
        parser.process(b"\x1b[?1000h\x1b[?1006h");
        assert_eq!(wheel_input(parser.screen(), 1, 2, 4).unwrap(), b"\x1b[<64;5;3M");
        assert_eq!(wheel_input(parser.screen(), -1, 999, 999).unwrap(), b"\x1b[<65;300;10M");
        parser.process(b"\x1b[?1006l");
        assert_eq!(wheel_input(parser.screen(), 1, 2, 4).unwrap(), b"\x1b[M`%#");
        parser.process(b"\x1b[?1005h");
        assert_eq!(wheel_input(parser.screen(), 1, 2, 299).unwrap(), "\x1b[M`\u{14c}#".as_bytes());
        assert!(wheel_input(parser.screen(), 0, 2, 4).unwrap().is_empty());
        assert!(wheel_input(parser.screen(), i32::MIN, 2, 4).unwrap().len() < 8192);
    }

    fn isolated_zsh(base: &Path, home: &Path) -> Option<std::process::Command> {
        let zsh = ["/bin/zsh", "/usr/bin/zsh"]
            .into_iter()
            .find(|path| Path::new(path).is_file());
        let Some(zsh) = zsh else {
            eprintln!("Skipping Zsh integration test: zsh is not installed");
            return None;
        };
        let mut command = std::process::Command::new(zsh);
        command
            .env_clear()
            .env("HOME", home)
            .env("PATH", "/usr/bin:/bin")
            .env("TERM", "xterm-256color")
            .env("ZDOTDIR", base)
            .current_dir(home)
            .args(local_shell_args(zsh));
        Some(command)
    }

    fn assert_zsh_success(mut command: std::process::Command, script: &str) {
        let output = command.args(["-c", script]).output().unwrap();
        assert!(
            output.status.success(),
            "Zsh failed: {:?}\nstdout: {}\nstderr: {}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn login_startup_loads_tool_path_before_installing_session_hooks() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("user's home");
        let base = temp.path().join("Nia session");
        let cargo_bin = home.join("custom rust/bin");
        fs::create_dir_all(&base).unwrap();
        fs::create_dir_all(&cargo_bin).unwrap();
        fs::write(
            home.join(".zshenv"),
            "typeset -ga nia_test_order=(env)\n[[ ! -v ZDOTDIR ]] || return 41\n",
        )
        .unwrap();
        fs::write(home.join(".zprofile"), "nia_test_order+=(profile)\nexport CARGO_HOME=\"$HOME/custom rust\"\nexport PATH=\"$CARGO_HOME/bin:$PATH\"\n").unwrap();
        fs::write(home.join(".zshrc"), "nia_test_order+=(rc)\n").unwrap();
        fs::write(
            home.join(".zlogin"),
            "nia_test_order+=(login)\nHISTFILE=\"$HOME/shared-history\"\n",
        )
        .unwrap();
        fs::write(
            cargo_bin.join("cargo"),
            "#!/bin/sh\nprintf 'test-cargo\\n'\n",
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(cargo_bin.join("cargo"), fs::Permissions::from_mode(0o700))
                .unwrap();
        }
        write_zsh_startup(&base, None).unwrap();
        let Some(mut command) = isolated_zsh(&base, &home) else {
            return;
        };
        command.env("NIA_EXPECTED_HISTORY", base.join("shell_history"));
        assert_zsh_success(
            command,
            r#"
            [[ -o login && -o interactive ]] || exit 42
            [[ ${(j:,:)nia_test_order} == env,profile,rc,login ]] || exit 43
            [[ $(cargo) == test-cargo ]] || exit 44
            [[ $HISTFILE == $NIA_EXPECTED_HISTORY ]] || exit 45
            [[ ! -v ZDOTDIR ]] || exit 46
            [[ ${preexec_functions[(I)_nia_mark_start]} -gt 0 ]] || exit 47
            [[ ${precmd_functions[(I)_ember_capture_state]} -gt 0 ]] || exit 48
            [[ ${widgets[accept-line]} == user:_nia_ai_accept_line ]] || exit 49
        "#,
        );
    }

    #[test]
    fn zshenv_redirect_keeps_user_config_hooks_and_nested_shells() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let custom = home.join("config zsh");
        let base = temp.path().join("session");
        fs::create_dir_all(&custom).unwrap();
        fs::create_dir_all(&base).unwrap();
        fs::write(
            home.join(".zshenv"),
            "export ZDOTDIR=\"$HOME/config zsh\"\n",
        )
        .unwrap();
        fs::write(custom.join(".zprofile"), "export NIA_TEST_PROFILE=loaded\n").unwrap();
        fs::write(custom.join(".zshrc"), "export NIA_TEST_RC=loaded\n").unwrap();
        fs::write(custom.join(".zlogin"), "export NIA_TEST_LOGIN=loaded\n").unwrap();
        write_zsh_startup(&base, None).unwrap();
        let Some(mut command) = isolated_zsh(&base, &home) else {
            return;
        };
        command
            .env("NIA_EXPECTED_ZDOTDIR", &custom)
            .env("NIA_EXPECTED_HISTORY", base.join("shell_history"));
        assert_zsh_success(
            command,
            r#"
            [[ $NIA_TEST_PROFILE:$NIA_TEST_RC:$NIA_TEST_LOGIN == loaded:loaded:loaded ]] || exit 51
            [[ $ZDOTDIR == $NIA_EXPECTED_ZDOTDIR ]] || exit 52
            [[ $HISTFILE == $NIA_EXPECTED_HISTORY ]] || exit 53
            [[ ${preexec_functions[(I)_nia_mark_start]} -gt 0 ]] || exit 54
            zsh -ic '[[ $ZDOTDIR == $NIA_EXPECTED_ZDOTDIR && $NIA_TEST_RC == loaded ]]' || exit 55
        "#,
        );
    }

    #[test]
    fn inherited_zdotdir_can_redirect_again_in_zprofile() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let original = home.join("original");
        let redirected = home.join("redirected");
        let base = temp.path().join("session");
        for dir in [&original, &redirected, &base] {
            fs::create_dir_all(dir).unwrap();
        }
        fs::write(home.join(".zshenv"), "exit 61\n").unwrap();
        fs::write(original.join(".zshenv"), "export NIA_TEST_ENV=loaded\n").unwrap();
        fs::write(
            original.join(".zprofile"),
            "export ZDOTDIR=\"$HOME/redirected\"\n",
        )
        .unwrap();
        fs::write(redirected.join(".zshrc"), "export NIA_TEST_RC=redirected\n").unwrap();
        fs::write(
            redirected.join(".zlogin"),
            "export NIA_TEST_LOGIN=redirected\n",
        )
        .unwrap();
        write_zsh_startup(&base, Some(&original)).unwrap();
        let Some(mut command) = isolated_zsh(&base, &home) else {
            return;
        };
        command.env("NIA_EXPECTED_ZDOTDIR", &redirected);
        assert_zsh_success(
            command,
            r#"
            [[ $NIA_TEST_ENV:$NIA_TEST_RC:$NIA_TEST_LOGIN == loaded:redirected:redirected ]] || exit 62
            [[ $ZDOTDIR == $NIA_EXPECTED_ZDOTDIR ]] || exit 63
            [[ ${preexec_functions[(I)_nia_mark_start]} -gt 0 ]] || exit 64
        "#,
        );
    }

    #[test]
    fn zlogin_redirect_and_venv_restore_run_before_first_command() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let redirected = home.join("after-login");
        let venv = home.join("python environment");
        let base = temp.path().join("session");
        for dir in [&redirected, &venv.join("bin"), &base] {
            fs::create_dir_all(dir).unwrap();
        }
        fs::write(
            home.join(".zlogin"),
            "export ZDOTDIR=\"$HOME/after-login\"\nexport PATH=/usr/bin:/bin\n",
        )
        .unwrap();
        fs::write(redirected.join(".zshrc"), "export NIA_NESTED_RC=loaded\n").unwrap();
        fs::write(
            venv.join("bin/activate"),
            "export VIRTUAL_ENV=\"$EMBER_RESTORE_VENV\"\nexport PATH=\"$VIRTUAL_ENV/bin:$PATH\"\n",
        )
        .unwrap();
        write_zsh_startup(&base, None).unwrap();
        let Some(mut command) = isolated_zsh(&base, &home) else {
            return;
        };
        command
            .env("EMBER_RESTORE_VENV", &venv)
            .env("NIA_EXPECTED_ZDOTDIR", &redirected);
        assert_zsh_success(
            command,
            r#"
            [[ $ZDOTDIR == $NIA_EXPECTED_ZDOTDIR ]] || exit 71
            [[ $VIRTUAL_ENV == $EMBER_RESTORE_VENV && $path[1] == $VIRTUAL_ENV/bin ]] || exit 72
            zsh -ic '[[ $NIA_NESTED_RC == loaded && $ZDOTDIR == $NIA_EXPECTED_ZDOTDIR ]]' || exit 73
        "#,
        );
    }

    #[test]
    fn nonlogin_interactive_shell_installs_hooks_and_no_rcs_keeps_user_directory() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let base = temp.path().join("session");
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&base).unwrap();
        fs::write(home.join(".zshrc"), "export NIA_TEST_RC=loaded\n").unwrap();
        write_zsh_startup(&base, None).unwrap();
        let Some(mut command) = isolated_zsh(&base, &home) else {
            return;
        };
        // -l was set by the production argument helper; explicitly turn it off.
        command.arg("+l");
        assert_zsh_success(command, "[[ $NIA_TEST_RC == loaded && ! -v ZDOTDIR && ${preexec_functions[(I)_nia_mark_start]} -gt 0 ]]");
        for name in [".zshenv", ".zprofile"] {
            fs::write(home.join(name), "unsetopt rcs\n").unwrap();
            let Some(command) = isolated_zsh(&base, &home) else {
                return;
            };
            assert_zsh_success(
                command,
                "[[ ! -v ZDOTDIR && -z ${NIA_TEST_RC-} && -o norcs ]]",
            );
            fs::remove_file(home.join(name)).unwrap();
        }
    }

    #[cfg(unix)]
    #[test]
    fn interactive_pty_loads_existing_session_history_after_login() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let base = temp.path().join("session");
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&base).unwrap();
        fs::write(home.join(".zlogin"), "HISTFILE=\"$HOME/shared-history\"\n").unwrap();
        fs::write(
            base.join("shell_history"),
            "echo previous-session-command\n",
        )
        .unwrap();
        write_zsh_startup(&base, None).unwrap();
        if isolated_zsh(&base, &home).is_none() {
            return;
        }

        // Zsh -c intentionally does not import history. Use an actual interactive
        // PTY and its normal input loop to test restoration, just as the app does.
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let mut command = CommandBuilder::new("/usr/bin/env");
        for arg in [
            "-i".to_owned(),
            format!("HOME={}", home.display()),
            "PATH=/usr/bin:/bin".to_owned(),
            "TERM=xterm-256color".to_owned(),
            format!("ZDOTDIR={}", base.display()),
            "zsh".to_owned(),
        ] {
            command.arg(arg);
        }
        for arg in local_shell_args("zsh") {
            command.arg(*arg);
        }
        command.cwd(&home);
        let mut child = pair.slave.spawn_command(command).unwrap();
        drop(pair.slave);
        // A real terminal consumes output while the shell runs. On macOS even
        // process exit can wait for unread PTY output to drain.
        let mut output = pair.master.try_clone_reader().unwrap();
        let output_worker = thread::spawn(move || {
            let _ = std::io::copy(&mut output, &mut std::io::sink());
        });
        let mut input = pair.master.take_writer().unwrap();
        let result = temp.path().join("restored-history");
        writeln!(input, "fc -ln 1 > {}", zsh_quote(&result)).unwrap();
        writeln!(input, "builtin exit").unwrap();
        input.flush().unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            if child.try_wait().unwrap().is_some() {
                break;
            }
            if std::time::Instant::now() >= deadline {
                let _ = child.kill();
                panic!("Zsh did not finish the isolated history test");
            }
            thread::sleep(std::time::Duration::from_millis(10));
        }
        drop(input);
        drop(pair.master);
        output_worker.join().unwrap();
        assert!(fs::read_to_string(result)
            .unwrap()
            .contains("echo previous-session-command"));
        assert!(!home.join("shared-history").exists());
    }

    #[test]
    fn shift_return_inserts_newline_until_plain_return_accepts_the_buffer() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let base = temp.path().join("session");
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&base).unwrap();
        let ready = temp.path().join("ready");
        fs::write(home.join(".zshrc"), format!(
            "function zle-line-init() {{ print ready > {}; }}\nzle -N zle-line-init\n", zsh_quote(&ready)
        )).unwrap();
        write_zsh_startup(&base,None).unwrap();
        if isolated_zsh(&base,&home).is_none() { return; }
        let pair = native_pty_system().openpty(PtySize { rows:24,cols:80,pixel_width:0,pixel_height:0 }).unwrap();
        let mut command = CommandBuilder::new("/usr/bin/env");
        for arg in ["-i".to_owned(),format!("HOME={}",home.display()),"PATH=/usr/bin:/bin".to_owned(),
            "TERM=xterm-256color".to_owned(),format!("ZDOTDIR={}",base.display()),"zsh".to_owned(),"-l".to_owned(),"-i".to_owned()] { command.arg(arg); }
        command.cwd(&home);
        let mut child = pair.slave.spawn_command(command).unwrap();
        drop(pair.slave);
        let mut output = pair.master.try_clone_reader().unwrap();
        let drain = thread::spawn(move || { let _ = std::io::copy(&mut output,&mut std::io::sink()); });
        let mut input = pair.master.take_writer().unwrap();
        let first = temp.path().join("first");
        let second = temp.path().join("second");
        let wait = |path: &Path| {
            let end = std::time::Instant::now() + std::time::Duration::from_secs(3);
            while !path.exists() && std::time::Instant::now() < end { thread::sleep(std::time::Duration::from_millis(10)); }
            path.exists()
        };
        let started = wait(&ready);
        input.write_all(format!("print -rn -- first > {}\x1b[13;2u",zsh_quote(&first)).as_bytes()).unwrap();
        input.flush().unwrap();
        thread::sleep(std::time::Duration::from_millis(150));
        let not_executed = !first.exists();
        input.write_all(format!("print -rn -- second > {}\r",zsh_quote(&second)).as_bytes()).unwrap();
        input.flush().unwrap();
        let submitted = wait(&second);
        let _ = child.kill();
        let _ = child.wait();
        drop(input); drop(pair.master); drain.join().unwrap();
        assert!(started,"Zsh must enter its real interactive line editor");
        assert!(not_executed,"Shift+Return must not execute the first command");
        assert!(submitted,"Plain Return must execute the multiline buffer");
        assert_eq!(fs::read_to_string(first).unwrap(),"first");
        assert_eq!(fs::read_to_string(second).unwrap(),"second");
    }

    #[test]
    fn startup_rewrite_drops_old_profiles_and_old_nia_wrapper_inheritance() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let old = temp.path().join("old-config");
        let empty = temp.path().join("empty-config");
        let base = temp.path().join("session");
        let nested = temp.path().join("new-session");
        for dir in [&home, &old, &empty, &base, &nested] {
            fs::create_dir_all(dir).unwrap();
        }
        fs::write(old.join(".zprofile"), "export NIA_STALE_PROFILE=bad\n").unwrap();
        fs::write(home.join(".zshenv"), "export NIA_TEST_HOME_ENV=loaded\n").unwrap();
        write_zsh_startup(&base, Some(&old)).unwrap();
        write_zsh_startup(&base, Some(&empty)).unwrap();
        let Some(command) = isolated_zsh(&base, &home) else {
            return;
        };
        assert_zsh_success(
            command,
            "[[ -z ${NIA_STALE_PROFILE-} && $ZDOTDIR == */empty-config ]]",
        );
        // Simulate launching the app from an older Nia that exported its wrapper.
        write_zsh_startup(&nested, Some(&base)).unwrap();
        let Some(mut command) = isolated_zsh(&nested, &home) else {
            return;
        };
        command.env("NIA_EXPECTED_HISTORY", nested.join("shell_history"));
        assert_zsh_success(command, "[[ $NIA_TEST_HOME_ENV == loaded && ! -v ZDOTDIR && $HISTFILE == $NIA_EXPECTED_HISTORY ]]");
    }

    #[cfg(unix)]
    #[test]
    fn live_resize_updates_both_pty_and_parser_from_bootstrap_dimensions() {
        let temp = tempfile::tempdir().unwrap();
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 30,
                cols: 100,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let child = pair
            .slave
            .spawn_command(CommandBuilder::new("/bin/cat"))
            .unwrap();
        let writer = pair.master.take_writer().unwrap();
        let (_tx, rx) = mpsc::channel();
        let mut terminal = LiveTerminal {
            history_view: None,
            parser: vt100::Parser::new(
                NonZeroU16::new(30).unwrap(),
                NonZeroU16::new(100).unwrap(),
                100,
            ),
            input: PtyInput::for_pty(pair.master.as_ref(), writer).unwrap(),
            master: pair.master,
            rx,
            remote: false,
            history_indexer: HistoryIndexer::default(),
            state_path: temp.path().join("state"),
            ai_request_path: None,
            exit_request_path: None,
            exit_approval_path: None,
            exit_observed_polls: 0,
            marks_file: None,
            marks_offset: 0,
            marks_buffer: Vec::new(),
            pending_mark: None,
            agent_resume_path: None,
            _child: child,
        };
        for (rows, cols) in [(80, 160), (24, 72), (50, 120)] {
            terminal.resize(rows, cols).unwrap();
            let actual = terminal.master.get_size().unwrap();
            assert_eq!((actual.rows, actual.cols), (rows, cols));
            let (parser_rows, parser_cols) = terminal.parser.screen().size();
            assert_eq!((parser_rows.get(), parser_cols.get()), (rows, cols));
        }
        terminal._child.kill().unwrap();
        terminal._child.wait().unwrap();
    }

    #[test]
    fn shell_quote_escapes_single_quotes() {
        assert_eq!(zsh_quote(Path::new("/tmp/a'b")), "'/tmp/a'\\''b'");
    }
    #[test]
    fn tmux_name_is_shell_safe_and_deterministic() {
        assert_eq!(remote_tmux_name("a'b"), "nia-612762");
    }
    #[test]
    fn agent_resume_accepts_explicit_safe_ids_only() {
        let id = "123e4567-e89b-12d3-a456-426614174000";
        assert_eq!(validated_agent_resume(&format!("claude --resume {id}")),
                   Some(format!("claude --resume {id}")));
        assert!(validated_agent_resume("claude --resume x; rm -rf ~").is_none());
        assert!(validated_agent_resume("sudo claude --resume 123e4567").is_none());
        assert!(validated_agent_resume("claude --continue").is_none());
    }
    #[test]
    fn ids_have_distinct_history_paths() {
        let a = session_base("alpha").unwrap();
        let b = session_base("beta").unwrap();
        assert_ne!(a, b);
    }
}
