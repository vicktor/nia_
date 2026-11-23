// SPDX-License-Identifier: MPL-2.0
use anyhow::{Context, Result};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::{fs::{self, File}, io::{Read, Seek, SeekFrom, Write}, num::NonZeroU16, path::{Path, PathBuf}, sync::mpsc::{self, Receiver}, thread};
use crate::{storage::SessionRecord, history::HistoryIndexer};

pub struct LiveTerminal {
    pub parser: vt100::Parser,
    pub input: Box<dyn Write + Send>,
    pub master: Box<dyn MasterPty + Send>,
    pub rx: Receiver<Vec<u8>>,
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
    pub fn spawn(record: SessionRecord, rows: u16, cols: u16, scrollback_lines: usize, remote_host: Option<&str>) -> Result<Self> {
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
            c.arg(format!("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH exec tmux new-session -A -s {}", remote_tmux_name(&record.id)));
            c
        } else {
            CommandBuilder::new(shell.as_str())
        };
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
        let mut reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let (tx, rx) = mpsc::channel();
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
            history_indexer: HistoryIndexer::default(), parser: vt100::Parser::new(NonZeroU16::new(rows).unwrap(), NonZeroU16::new(cols).unwrap(), scrollback_lines),
            input: writer, master: pair.master, rx, _child: child };
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

    pub fn send(&mut self, bytes: &[u8]) -> Result<()> { self.input.write_all(bytes)?; self.input.flush()?; Ok(()) }
    pub fn resize(&mut self, rows: u16, cols: u16) -> Result<()> {
        let rows = rows.max(1);
        let cols = cols.max(1);
        self.master.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })?;
        self.parser.set_size(NonZeroU16::new(rows).unwrap(), NonZeroU16::new(cols).unwrap());
        Ok(())
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

fn prepare_zsh_history(id: &str) -> Result<PathBuf> {
    let base = session_base(id)?;
    let original = std::env::var_os("ZDOTDIR").map(PathBuf::from)
        .or_else(dirs::home_dir).context("cannot find zsh startup directory")?;
    for name in [".zshenv", ".zprofile", ".zlogin"] {
        let source = original.join(name);
        if source.exists() && source != base.join(name) {
            fs::write(base.join(name), format!("[[ -f {0} ]] && source {0}\n", zsh_quote(&source)))?;
        }
    }
    // A query left by a previous crashed process is not a new request.
    let _ = fs::remove_file(base.join("ai-request"));
    let _ = fs::remove_file(base.join("exit-request"));
    let _ = fs::remove_file(base.join("exit-approved"));
    let original_rc = original.join(".zshrc");
    let history = base.join("shell_history");
    // Create an owner-only history file, also protecting existing installations.
    let _file = fs::OpenOptions::new().create(true).append(true).open(&history)?;
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&history, fs::Permissions::from_mode(0o600))?;
    }
    let content = format!("# Generated by Nia; preserve user's normal Zsh setup.\n\
        [[ -f {0} ]] && source {0}\n\
        HISTFILE={1}\n\
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
          local tmp={2}.tmp.$$\n\
          ( umask 077; print -r -- \"$PWD\" > \"$tmp\"; print -r -- \"${{VIRTUAL_ENV:-}}\" >> \"$tmp\" )\n\
          command mv -f -- \"$tmp\" {2}\n\
        }}\n\
        autoload -Uz add-zsh-hook\n\
        # Command timeline: built-in Zsh hooks, no subprocess or prompt edits.\n\
        zmodload zsh/datetime 2>/dev/null\n\
        function _nia_mark_start() {{\n\
          builtin printf 'S\\0%s\\0%s\\0%s\\0' \"$EPOCHREALTIME\" \"$PWD\" \"$1\" >> {6}\n\
        }}\n\
        function _nia_mark_end() {{\n\
          local exit_status=$?\n\
          builtin printf 'E\\0%s\\0%s\\0' \"$EPOCHREALTIME\" \"$exit_status\" >> {6}\n\
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
              local tmp={3}.tmp.$$\n\
              ( umask 077; print -rn -- \"$question\" > \"$tmp\" )\n\
              command mv -f -- \"$tmp\" {3}\n\
              BUFFER=''\n\
              CURSOR=0\n\
              zle reset-prompt\n\
              return 0\n\
            fi\n\
          fi\n\
          # Intercept only the literal exit/logout line, before the shell sees it.\n\
          # The UI asks for consent and later creates a one-shot approval file.\n\
          if [[ $BUFFER == exit || $BUFFER == logout ]]; then\n\
            if [[ -f {4} ]]; then\n\
              command rm -f -- {4}\n\
              zle .accept-line\n\
              return 0\n\
            fi\n\
            local tmp={5}.tmp.$$\n\
            ( umask 077; print -r -- exit > \"$tmp\" )\n\
            command mv -f -- \"$tmp\" {5}\n\
            BUFFER=''\n\
            CURSOR=0\n\
            zle reset-prompt\n\
            return 0\n\
          fi\n\
          zle .accept-line\n\
        }}\n\
        zle -N accept-line _nia_ai_accept_line\n",
        zsh_quote(&original_rc), zsh_quote(&history), zsh_quote(&base.join("state")), zsh_quote(&base.join("ai-request")),
        zsh_quote(&base.join("exit-approved")), zsh_quote(&base.join("exit-request")),
        zsh_quote(&base.join("command-marks")));
    fs::write(base.join(".zshrc"), content)?;
    Ok(base)
}

#[cfg(test)]
mod history_tests {
    use super::*;
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
