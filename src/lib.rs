// SPDX-License-Identifier: MPL-2.0
//! Native macOS bridge. The legacy egui executable remains available for comparison.
mod storage;
mod history;
mod terminal;

use std::{collections::HashMap, ffi::{CStr, CString, c_char}, os::raw::c_int, ptr};
use serde::Serialize;
use storage::{SessionRecord, Store};
use terminal::LiveTerminal;


#[derive(Clone, Copy)]
struct DiskScroll { offset: u64, max_offset: u64 }

pub struct NiaCore {
    store: Store,
    records: Vec<SessionRecord>,
    live: HashMap<String, LiveTerminal>,
    last_error: String,
    scrollback_lines: usize,
    disk_scroll: HashMap<String, DiskScroll>,
    ai_queries: Vec<AIQuery>,
}

#[derive(Serialize)]
struct AIQuery { session_id: String, question: String }

#[derive(Serialize)]
struct SessionInfo<'a> { id: &'a str, cwd: &'a str, closed: bool, venv: &'a Option<String>, color: String, remote_host: Option<String> }
#[derive(Serialize, Clone)]
struct CellData { t: String, fg: i32, bg: i32, flags: u8, wide: bool, continuation: bool }
#[derive(Serialize)]
struct ScreenData { session_id: String, cells: Vec<Vec<CellData>>, cursor_row: u16, cursor_col: u16, cursor_visible: bool, rows: u16, cols: u16, scrollback_offset: usize }
// Encoded colors: -1 = terminal default; 0..255 = indexed palette; 0x1000000 | RGB = true color.
fn encode_color(color: vt100::Color) -> i32 {
    match color { vt100::Color::Default => -1, vt100::Color::Idx(n) => i32::from(n),
        vt100::Color::Rgb(r,g,b) => 0x1000000 | (i32::from(r) << 16) | (i32::from(g) << 8) | i32::from(b) }
}

fn to_c(value: impl AsRef<str>) -> *mut c_char {
    let clean = value.as_ref().replace('\0', "�");
    CString::new(clean).unwrap_or_default().into_raw()
}
fn json<T: Serialize>(value: &T) -> *mut c_char {
    match serde_json::to_string(value) { Ok(s) => to_c(s), Err(e) => to_c(format!("{{\"error\":{}}}", serde_json::to_string(&e.to_string()).unwrap_or_default())) }
}
unsafe fn text_arg<'a>(p: *const c_char) -> Result<&'a str, String> {
    if p.is_null() { return Err("null argument".into()); }
    CStr::from_ptr(p).to_str().map_err(|e| e.to_string())
}
impl NiaCore {
    fn set_error(&mut self, value: impl ToString) -> c_int { self.last_error = value.to_string(); -1 }
    fn refresh(&mut self) {
        // Keep sessions alive even when they aren't visible.
        for (id, term) in &mut self.live {
            match term.take_ai_request() {
                Ok(Some(question)) => self.ai_queries.push(AIQuery { session_id: id.clone(), question }),
                Ok(None) => {},
                Err(error) => self.last_error = format!("AI request: {error}"),
            }
            if self.store.remote_host(id).ok().flatten().is_none() {
                if let Ok(Some((cwd, venv))) = term.snapshot_state() {
                    if let Some(rec) = self.records.iter_mut().find(|r| r.id == *id) {
                        if rec.cwd != cwd || rec.venv != venv {
                            rec.cwd = cwd;
                            rec.venv = venv;
                            if let Err(e) = self.store.upsert(rec) { self.last_error = e.to_string(); }
                        }
                    }
                }
            }
            let mut chunk = Vec::new();
            while let Ok(bytes) = term.rx.try_recv() {
                chunk.extend_from_slice(&bytes);
                if chunk.len() >= 128 * 1024 { break; }
            }
            if !chunk.is_empty() {
                match self.store.log_file(id).and_then(|mut f| Store::append_and_sync(&mut f, &chunk)) {
                    Ok(()) => {
                        term.parser.process(&chunk);
                        let lines = term.history_indexer.ingest(&chunk);
                        if let Err(e) = self.store.append_history_lines(id, &lines) {
                            self.last_error = format!("History index: {e}");
                        }
                    },
                    Err(e) => self.last_error = e.to_string(),
                }
            }
        }
    }
    fn open(&mut self, id: &str) -> Result<(), String> {
        let record = self.records.iter_mut().find(|r| r.id == id).ok_or("Session not found")?;
        record.closed = false;
        self.store.upsert(record).map_err(|e| e.to_string())?;
        self.disk_scroll.remove(id);
        if !self.live.contains_key(id) {
            let remote_host = self.store.remote_host(id).map_err(|e| e.to_string())?;
            let mut term = LiveTerminal::spawn(record.clone(), 30, 100, self.scrollback_lines, remote_host.as_deref())
                .map_err(|e| e.to_string())?;
            // Remote tmux redraws its live screen after the SSH attachment.
            // Don't replay a stale local transcript into a live remote PTY.
            if remote_host.is_none() {
                self.store.replay_stream(id, |chunk| term.parser.process(chunk))
                    .map_err(|e| format!("Cannot restore session {id}: {e}"))?;
            }
            self.live.insert(id.to_string(), term);
        }
        Ok(())
    }
}

#[no_mangle]
pub extern "C" fn nia_core_new() -> *mut NiaCore {
    match Store::open().and_then(|store| { let records = store.list()?; Ok((store, records)) }) {
        Ok((store, records)) => Box::into_raw(Box::new(NiaCore { store, records, live: HashMap::new(), last_error: String::new(), scrollback_lines: 10000, disk_scroll: HashMap::new(), ai_queries: Vec::new() })),
        Err(e) => { eprintln!("Nia storage initialization failed: {e:#}"); ptr::null_mut() }
    }
}
#[no_mangle]
pub unsafe extern "C" fn nia_core_free(p: *mut NiaCore) {
    if !p.is_null() { drop(Box::from_raw(p)); }
}
#[no_mangle]
pub unsafe extern "C" fn nia_string_free(p: *mut c_char) {
    if !p.is_null() { drop(CString::from_raw(p)); }
}
#[no_mangle]
pub unsafe extern "C" fn nia_last_error(p: *mut NiaCore) -> *mut c_char {
    if p.is_null() { return to_c("Nia core unavailable"); }
    to_c(&(*p).last_error)
}
/// Drain pending local Zsh queries once, without forwarding them to the PTY.
#[no_mangle]
pub unsafe extern "C" fn nia_take_ai_queries(p: *mut NiaCore) -> *mut c_char {
    if p.is_null() { return to_c("[]") }
    let core = &mut *p;
    json(&std::mem::take(&mut core.ai_queries))
}

#[no_mangle]
pub unsafe extern "C" fn nia_sessions(p: *mut NiaCore) -> *mut c_char {
    if p.is_null() { return to_c("[]"); }
    let core = &*p;
    let records: Vec<_> = core.records.iter().map(|r| SessionInfo { id: &r.id, cwd: &r.cwd, closed: r.closed, venv: &r.venv, color: core.store.session_color(&r.id).unwrap_or_else(|_| "#648ACA".to_string()), remote_host: core.store.remote_host(&r.id).ok().flatten() }).collect();
    json(&records)
}
/// Returns the atomic workspace layout saved in the existing Nia database.
#[no_mangle]
pub unsafe extern "C" fn nia_workspace_layout(p: *mut NiaCore) -> *mut c_char {
    if p.is_null() { return to_c(""); }
    let core = &*p;
    match core.store.workspace_layout() {
        Ok(Some(value)) => to_c(value),
        Ok(None) => to_c(""),
        Err(_) => to_c(""),
    }
}

/// Persists both pane IDs, split orientation and focused pane together.
#[no_mangle]
pub unsafe extern "C" fn nia_save_workspace_layout(p: *mut NiaCore, layout: *const c_char) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let input = match text_arg(layout) { Ok(s) => s, Err(e) => return core.set_error(e) };
    if input.len() > 4096 { return core.set_error("Workspace layout too large"); }
    let value: serde_json::Value = match serde_json::from_str(input) {
        Ok(v) => v,
        Err(e) => return core.set_error(e),
    };
    let valid_mode = matches!(value.get("mode").and_then(|v| v.as_str()), Some("off" | "vertical" | "horizontal"));
    // Swift's synthesized Codable omits nil Optionals. Missing and null
    // are both legitimate, especially in single-pane mode.
    let valid_primary = value.get("primary").map_or(true, |v| v.is_null() || v.as_str().is_some());
    let valid_secondary = value.get("secondary").map_or(true, |v| v.is_null() || v.as_str().is_some());
    let valid_pane = matches!(value.get("focusedPane").and_then(|v| v.as_u64()), Some(0 | 1));
    if !valid_mode || !valid_primary || !valid_secondary || !valid_pane {
        return core.set_error("Invalid workspace layout");
    }
    let primary = value["primary"].as_str();
    let secondary = value["secondary"].as_str();
    if primary.is_some_and(|id| !core.records.iter().any(|r| r.id == id && !r.closed))
        || secondary.is_some_and(|id| !core.records.iter().any(|r| r.id == id && !r.closed)) {
        return core.set_error("Workspace refers to a missing or archived session");
    }
    match core.store.save_workspace_layout(input) {
        Ok(()) => 0,
        Err(e) => core.set_error(e),
    }
}

#[no_mangle]
pub unsafe extern "C" fn nia_move_session(p: *mut NiaCore, source: *const c_char, target: *const c_char) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let source = match text_arg(source) { Ok(s) => s, Err(e) => return core.set_error(e) };
    let target = match text_arg(target) { Ok(s) => s, Err(e) => return core.set_error(e) };
    if let Err(e) = core.store.move_session(source, target) { return core.set_error(e); }
    match core.store.list() {
        Ok(records) => { core.records = records; 0 },
        Err(e) => core.set_error(e),
    }
}

#[no_mangle]
pub unsafe extern "C" fn nia_move_session_relative(
    p: *mut NiaCore, source: *const c_char, target: *const c_char, after: c_int
) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let source = match text_arg(source) { Ok(s) => s, Err(e) => return core.set_error(e) };
    let target = match text_arg(target) { Ok(s) => s, Err(e) => return core.set_error(e) };
    if let Err(e) = core.store.move_session_relative(source, target, after != 0) {
        return core.set_error(e);
    }
    match core.store.list() {
        Ok(records) => { core.records = records; 0 },
        Err(e) => core.set_error(e),
    }
}

#[no_mangle]
pub unsafe extern "C" fn nia_create_session(p: *mut NiaCore, name: *const c_char) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) { Ok(s) => s.trim(), Err(e) => return core.set_error(e) };
    if id.is_empty() || id.len() > 64 || id.chars().any(|c| c.is_control() || c == '/' || c == '\\') {
        return core.set_error("Session name must be 1–64 bytes without slashes or controls");
    }
    if core.records.iter().any(|r| r.id == id) { return nia_open_session(p, name); }
    let rec = SessionRecord { id: id.to_string(), cwd: dirs::home_dir().unwrap_or_default().to_string_lossy().into_owned(), venv: None, closed: false };
    if let Err(e) = core.store.upsert(&rec) { return core.set_error(e); }
    core.records.push(rec);
    if let Err(e) = core.open(id) { return core.set_error(e); }
    0
}
/// Register an authenticated SSH + tmux session.
/// Host must be a trusted OpenSSH config alias or user@hostname; SSH verifies known_hosts.
#[no_mangle]
pub unsafe extern "C" fn nia_create_remote_session(
    p: *mut NiaCore, name: *const c_char, ssh_host: *const c_char
) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) { Ok(v) => v.trim(), Err(e) => return core.set_error(e) };
    let host = match text_arg(ssh_host) { Ok(v) => v.trim(), Err(e) => return core.set_error(e) };
    if id.is_empty() || id.len() > 64 || id.chars().any(|c| c.is_control() || c == '/' || c == '\\') {
        return core.set_error("Invalid session ID");
    }
    if host.is_empty() || host.len() > 253 || host.starts_with('-') ||
       !host.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.'|b'-'|b'_'|b'@')) ||
       host.matches('@').count() > 1 {
        return core.set_error("Use an SSH alias or user@host (letters, digits, dots, underscores, hyphens)");
    }
    if core.records.iter().any(|r| r.id == id) {
        return core.set_error("Session name already exists");
    }
    let rec = SessionRecord { id: id.to_owned(), cwd: format!("SSH: {host}"), venv: None, closed: false };
    if let Err(e) = core.store.upsert(&rec).and_then(|_| core.store.set_remote_host(id, host)) {
        return core.set_error(e);
    }
    core.records.push(rec);
    match core.open(id) { Ok(()) => 0, Err(e) => core.set_error(e) }
}

#[no_mangle]
pub unsafe extern "C" fn nia_open_session(p: *mut NiaCore, name: *const c_char) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) { Ok(s) => s, Err(e) => return core.set_error(e) };
    match core.open(id) { Ok(()) => 0, Err(e) => core.set_error(e) }
}
/// Explicitly reconnect a remote SSH client to its existing server-side tmux.
/// The tmux server and processes on the remote host are not terminated.
#[no_mangle]
pub unsafe extern "C" fn nia_reconnect_remote_session(
    p: *mut NiaCore, name: *const c_char
) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) { Ok(v) => v, Err(e) => return core.set_error(e) };
    match core.store.remote_host(id) {
        Ok(Some(_)) => {},
        Ok(None) => return core.set_error("This is not a remote session"),
        Err(e) => return core.set_error(e),
    }
    // Dropping the local SSH child disconnects the client; the remote tmux
    // session continues running under the remote user account.
    core.live.remove(id);
    match core.open(id) { Ok(()) => 0, Err(e) => core.set_error(e) }
}

#[no_mangle]
pub unsafe extern "C" fn nia_archive_session(p: *mut NiaCore, name: *const c_char) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) { Ok(s) => s, Err(e) => return core.set_error(e) };
    if let Err(e) = core.store.close(id) { return core.set_error(e); }
    if let Some(rec) = core.records.iter_mut().find(|r| r.id == id) { rec.closed = true; }
    core.live.remove(id);
    core.disk_scroll.remove(id);
    0
}
#[no_mangle]
pub unsafe extern "C" fn nia_send(p: *mut NiaCore, name: *const c_char, data: *const u8, len: usize) -> c_int {
    if p.is_null() || (data.is_null() && len > 0) { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) { Ok(s) => s, Err(e) => return core.set_error(e) };
    if len > 1024 * 1024 { return core.set_error("Input chunk too large"); }
    match core.live.get_mut(id) {
        Some(term) => match term.send(std::slice::from_raw_parts(if len == 0 { std::ptr::NonNull::<u8>::dangling().as_ptr() } else { data }, len)) {
            Ok(()) => 0, Err(e) => core.set_error(e)
        },
        None => core.set_error("Session not running"),
    }
}
/// Update the PTY window size immediately, without replaying the ANSI log.
/// The shell must see the new column count before it emits its next line.
#[no_mangle]
pub unsafe extern "C" fn nia_resize_fast(p: *mut NiaCore, name: *const c_char, rows: u16, cols: u16) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) { Ok(s) => s, Err(e) => return core.set_error(e) };
    let Some(term) = core.live.get_mut(id) else { return core.set_error("Session not running"); };
    let rows = rows.max(1);
    let cols = cols.max(1);
    let (current_rows, current_cols) = term.parser.screen().size();
    if current_rows.get() == rows && current_cols.get() == cols { return 0; }
    match term.resize(rows, cols) {
        Ok(()) => { core.disk_scroll.remove(id); 0 },
        Err(e) => core.set_error(e),
    }
}

/// Legacy ABI kept for compatibility with older Swift bundles.
/// Replaying a live session's historical PTY transcript at a different width
/// is NOT reflow: shell redraws, prompts and terminal control sequences are
/// reapplied and can visibly duplicate content. Never replay over a live PTY.
#[no_mangle]
pub unsafe extern "C" fn nia_reflow(_p: *mut NiaCore, _name: *const c_char) -> c_int {
    0
}

/// Resize the live PTY and grid only; history stays intact on disk.
#[no_mangle]
pub unsafe extern "C" fn nia_resize(p: *mut NiaCore, name: *const c_char, rows: u16, cols: u16) -> c_int {
    nia_resize_fast(p, name, rows, cols)
}
#[no_mangle]
pub unsafe extern "C" fn nia_poll(p: *mut NiaCore) {
    if !p.is_null() { (*p).refresh(); }
}
#[no_mangle]
pub unsafe extern "C" fn nia_screen(p: *mut NiaCore, name: *const c_char) -> *mut c_char {
    if p.is_null() { return to_c("{}"); }
    let core = &*p;
    let id = match text_arg(name) { Ok(s) => s, Err(e) => return to_c(e) };
    let Some(term) = core.live.get(id) else { return to_c("{}"); };
    let screen = term.parser.screen();
    let (height,width) = screen.size();
    if let Some(state) = core.disk_scroll.get(id) {
        // The count was captured on entry to disk history; do not issue
        // a full-table COUNT query on every 120 ms render tick.
        let offset = state.offset.min(state.max_offset);
        // Deep history: only a viewport-sized page is materialized. The original
        // VT stream remains on disk separately for lossless forensic recovery.
        let line_count = height.get() as usize;
        let lines = core.store.history_visible_page(id, offset, line_count).unwrap_or_default();
        if !lines.is_empty() {
        let mut grid = vec![];
        let padding = line_count.saturating_sub(lines.len());
        for _ in 0..padding { grid.push(vec![CellData { t: " ".into(), fg:-1,bg:-1,flags:0,wide:false,continuation:false }; width.get() as usize]); }
        for line in lines {
            let mut cells = line.chars().take(width.get() as usize).map(|ch| CellData {
                t:ch.to_string(), fg:-1,bg:-1,flags:0,wide:false,continuation:false
            }).collect::<Vec<_>>();
            while cells.len() < width.get() as usize { cells.push(CellData {t:" ".into(),fg:-1,bg:-1,flags:0,wide:false,continuation:false}); }
            grid.push(cells);
        }
        return json(&ScreenData {session_id:id.to_string(),cells:grid,cursor_row:0,cursor_col:0,cursor_visible:false,
            rows:height.get(),cols:width.get(),scrollback_offset: offset as usize});
        }
    }
    let mut grid = Vec::with_capacity(height.get() as usize);
    for row in 0..height.get() {
        let mut line = Vec::with_capacity(width.get() as usize);
        for col in 0..width.get() {
            if let Some(cell) = screen.cell(row,col) {
                let flags = (cell.bold() as u8) | ((cell.dim() as u8) << 1)
                    | ((cell.italic() as u8) << 2) | ((cell.underline() as u8) << 3)
                    | ((cell.inverse() as u8) << 4);
                line.push(CellData { t: cell.contents().to_string(), fg: encode_color(cell.fgcolor()),
                    bg: encode_color(cell.bgcolor()), flags, wide: cell.is_wide(),
                    continuation: cell.is_wide_continuation() });
            }
        }
        grid.push(line);
    }
    let (cursor_row,cursor_col) = screen.cursor_position();
    json(&ScreenData { session_id:id.to_string(), cells: grid, cursor_row, cursor_col, cursor_visible: !screen.hide_cursor(),
        rows: height.get(), cols: width.get(), scrollback_offset: screen.scrollback() })
}

/// Persist an opaque RGB color for a named session without changing session identity.
#[no_mangle]
pub unsafe extern "C" fn nia_set_session_color(p: *mut NiaCore, name: *const c_char, color: *const c_char) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) { Ok(s) => s, Err(e) => return core.set_error(e) };
    let value = match text_arg(color) { Ok(s) => s, Err(e) => return core.set_error(e) };
    let valid = value.len() == 7 && value.starts_with('#') && value.as_bytes()[1..].iter().all(|b| b.is_ascii_hexdigit());
    if !valid { return core.set_error("Color must be #RRGGBB"); }
    if !core.records.iter().any(|s| s.id == id) { return core.set_error("Session not found"); }
    match core.store.set_session_color(id, value) { Ok(()) => 0, Err(e) => core.set_error(e) }
}

/// Configure the in-memory scrollback cap for terminals opened after this call.
/// Existing PTYs retain their current capacity until reopened.
#[no_mangle]
pub unsafe extern "C" fn nia_set_scrollback_limit(p: *mut NiaCore, lines: u32) -> c_int {
    if p.is_null() { return -1; }
    if !(1000..=100000).contains(&lines) { return (*p).set_error("Scrollback must be between 1,000 and 100,000 lines"); }
    (*p).scrollback_lines = lines as usize;
    0
}

/// Positive delta scrolls into older output; negative delta returns toward live output.
#[no_mangle]
pub unsafe extern "C" fn nia_scroll(p: *mut NiaCore, name: *const c_char, delta: i32) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) { Ok(s) => s, Err(e) => return core.set_error(e) };
    let Some(term) = core.live.get_mut(id) else { return core.set_error("Session not running"); };
    if core.disk_scroll.contains_key(id) {
        let state = core.disk_scroll.get_mut(id).expect("checked above");
        let max_offset = state.max_offset;
        if delta > 0 {
            state.offset = state.offset.saturating_add(delta as u64).min(max_offset);
        } else {
            state.offset = state.offset.saturating_sub(delta.unsigned_abs() as u64);
        }
        if delta < 0 && state.offset == 0 { core.disk_scroll.remove(id); }
        return 0;
    }
    let offset = term.parser.screen().scrollback();
    let next = if delta >= 0 { offset.saturating_add(delta as usize) }
               else { offset.saturating_sub(delta.unsigned_abs() as usize) };
    term.parser.screen_mut().set_scrollback(next);
    if delta > 0 && term.parser.screen().scrollback() == offset {
        // Reached the in-memory limit. Enter indexed text history.
        let total = core.store.history_visible_count(id).unwrap_or(0);
        let viewport = term.parser.screen().size().0.get() as u64;
        let max_offset = total.saturating_sub(viewport);
        if max_offset > 0 {
            core.disk_scroll.insert(id.to_string(), DiskScroll {
                offset: (delta as u64).min(max_offset), max_offset
            });
        }
    }
    0
}

#[cfg(test)]
mod reflow_tests {
    use std::num::NonZeroU16;
    #[test]
    fn replay_at_new_width_keeps_full_unbroken_line() {
        let payload = b"0123456789ABCDEFGHIJ\r\n";
        let mut parser = vt100::Parser::new(NonZeroU16::new(10).unwrap(), NonZeroU16::new(30).unwrap(), 100);
        parser.process(payload);
        assert!(parser.screen().rows(0, 30).any(|r| r.contains("0123456789ABCDEFGHIJ")));
        let mut small = vt100::Parser::new(NonZeroU16::new(10).unwrap(), NonZeroU16::new(10).unwrap(), 100);
        small.process(payload);
        assert!(small.screen().rows(0, 10).any(|r| r.contains("0123456789")));
        // A resize to a wider grid reconstructs the visible lines from the log,
        // rather than keeping the old truncation caused by set_size alone.
        let mut wider = vt100::Parser::new(NonZeroU16::new(10).unwrap(), NonZeroU16::new(30).unwrap(), 100);
        wider.process(payload);
        assert!(wider.screen().rows(0, 30).any(|r| r.contains("0123456789ABCDEFGHIJ")));
    }
}
