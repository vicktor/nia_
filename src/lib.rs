// SPDX-License-Identifier: MPL-2.0
//! Native macOS bridge. The legacy egui executable remains available for comparison.
mod storage;
mod history;
mod terminal;
mod persistence;
mod pty_input;
mod update_archive;
mod sync_store;

use std::{collections::HashMap, ffi::{CStr, CString, c_char}, os::raw::c_int, ptr};
use serde::Serialize;
use storage::{SessionRecord, Store};
use terminal::LiveTerminal;
use persistence::{Persistence, PersistenceJob};

const PERSISTENCE_CONTROL_RESERVE: usize = 1024 * 1024;

// Independent of NiaCore: archive I/O runs off the UI thread and never opens
// the session database. Destination must not exist.
#[no_mangle]
pub unsafe extern "C" fn nia_unpack_update(archive: *const c_char, destination: *const c_char) -> c_int {
    let result = std::panic::catch_unwind(|| {
        let archive = text_arg(archive).map_err(anyhow::Error::msg)?;
        let destination = text_arg(destination).map_err(anyhow::Error::msg)?;
        update_archive::unpack(std::path::Path::new(archive), std::path::Path::new(destination))
    });
    if matches!(result, Ok(Ok(()))) { 0 } else { -1 }
}

/// Uses an independent database connection; call on a background queue.
#[no_mangle]
pub unsafe extern "C" fn nia_sync_request(request: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let request = text_arg(request).map_err(anyhow::Error::msg)?;
        sync_store::request(request)
    });
    match result {
        Ok(Ok(value)) => json(&value),
        Ok(Err(error)) => json(&serde_json::json!({"error": error.to_string()})),
        Err(_) => json(&serde_json::json!({"error": "Sync storage failed"})),
    }
}

/// Refresh only newly imported records. Never replace live in-memory state.
#[no_mangle]
pub unsafe extern "C" fn nia_reload_sessions(p: *mut NiaCore) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    match core.store.list() {
        Ok(records) => {
            for record in records {
                if !core.records.iter().any(|r| r.id == record.id) { core.records.push(record); }
            }
            0
        }
        Err(error) => core.set_error(error),
    }
}


#[derive(Clone, Copy)]
struct DiskScroll {
    first_line: i64,
}

pub struct NiaCore {
    store: Store,
    persistence: Persistence,
    pending_persistence: Option<PersistenceJob>,
    screen_generations: HashMap<String, u64>,
    next_screen_generation: u64,
    poll_cursor: usize,
    records: Vec<SessionRecord>,
    live: HashMap<String, LiveTerminal>,
    last_error: String,
    scrollback_lines: usize,
    disk_scroll: HashMap<String, DiskScroll>,
    ai_queries: Vec<AIQuery>,
    exit_requests: Vec<String>,
}

#[derive(Serialize)]
struct AIQuery { session_id: String, question: String }

#[derive(Serialize)]
struct SessionInfo<'a> { id: &'a str, display_name: String, cwd: &'a str, closed: bool, dismissed: bool, venv: &'a Option<String>, color: String, remote_host: Option<String> }
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
    fn set_error(&mut self, value: impl ToString) -> c_int {
        self.last_error = value.to_string();
        -1
    }
    fn invalidate_screen(&mut self, id: &str) {
        self.next_screen_generation = self.next_screen_generation.wrapping_add(1).max(1);
        self.screen_generations
            .insert(id.to_owned(), self.next_screen_generation);
    }

    fn enqueue(&mut self, job: PersistenceJob) -> bool {
        match self.persistence.try_enqueue(job) {
            Ok(_) => true,
            Err(job) => {
                self.pending_persistence = Some(job);
                false
            }
        }
    }

    fn retry_pending(&mut self) -> bool {
        match self.pending_persistence.take() {
            Some(job) => self.enqueue(job),
            None => true,
        }
    }

    fn persistence_feedback(&mut self) -> bool {
        let (error, changed) = self.persistence.feedback();
        for id in changed {
            if self.disk_scroll.contains_key(&id) {
                self.invalidate_screen(&id);
            }
        }
        if let Some(error) = error {
            self.last_error = error;
            false
        } else {
            true
        }
    }

    fn ensure_history_index(&mut self, id: &str) -> Result<(), String> {
        // Rebuilding must see every preceding output byte, and the worker must
        // continue from the rebuilt partial UTF-8/line/escape state afterward.
        self.flush_persistence()?;
        if let Some(indexer) = self
            .store
            .ensure_history_index(id)
            .map_err(|e| e.to_string())?
        {
            self.persistence
                .set_indexer(id, indexer.clone())
                .map_err(|e| e.to_string())?;
            if let Some(term) = self.live.get_mut(id) {
                term.history_indexer = indexer;
            }
        }
        Ok(())
    }

    fn flush_persistence(&mut self) -> Result<(), String> {
        self.flush_persistence_until(std::time::Instant::now() + std::time::Duration::from_secs(5))
    }

    fn flush_persistence_until(&mut self, deadline: std::time::Instant) -> Result<(), String> {
        let wait = |writer: &Persistence| {
            writer
                .flush_with_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
                .map_err(|error| error.to_string())
        };
        if self.pending_persistence.is_some() {
            wait(&self.persistence)?;
            if !self.retry_pending() {
                return Err("Terminal persistence queue is unavailable".into());
            }
        }
        wait(&self.persistence)
    }

    /// The display path does no filesystem/SQLite work. An 8 MiB persistence
    /// queue and 64-packet PTY reader queue bound memory when the disk is slow.
    fn refresh(&mut self) {
        self.persistence_feedback();
        if !self.retry_pending() {
            return;
        }
        let mut ids: Vec<_> = self.live.keys().cloned().collect();
        ids.sort_unstable();
        if ids.is_empty() {
            return;
        }
        let start = self.poll_cursor % ids.len();
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(4);
        let mut total = 0;
        for step in 0..ids.len() {
            let index = (start + step) % ids.len();
            let id = &ids[index];
            self.poll_cursor = (index + 1) % ids.len();
            // Each reader packet is <=8 KiB, so this covers the cap overshoot.
            if !self.persistence.can_accept(
                128 * 1024
                    + 8192
                    + persistence::JOB_OVERHEAD
                    + id.len()
                    + PERSISTENCE_CONTROL_RESERVE,
            ) {
                break;
            }
            let chunk = self.take_output(id, 128 * 1024, usize::MAX);
            total += chunk.len();
            if !chunk.is_empty() && !self.enqueue(PersistenceJob::output(id, chunk)) {
                break;
            }
            if total >= 512 * 1024 || (total > 0 && std::time::Instant::now() >= deadline) {
                break;
            }
        }
    }

    fn take_output(&mut self, id: &str, byte_limit: usize, packet_limit: usize) -> Vec<u8> {
        let Some(term) = self.live.get_mut(id) else {
            return Vec::new();
        };
        let mut chunk = Vec::new();
        for _ in 0..packet_limit {
            match term.rx.try_recv() {
                Ok(bytes) => {
                    chunk.extend_from_slice(&bytes);
                    if chunk.len() >= byte_limit {
                        break;
                    }
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    term.exit_observed_polls = 1;
                    break;
                }
            }
        }
        if !chunk.is_empty() {
            term.parser.process(&chunk);
            self.invalidate_screen(id);
        }
        chunk
    }

    /// Shared native maintenance calls this at 500 ms, independently of frames.
    /// History writes are queued; metadata and agent-resume work stays on this slower path.
    fn maintain(&mut self) -> Result<(), String> {
        self.maintain_sessions(None)
    }

    fn maintain_sessions(&mut self, only: Option<&str>) -> Result<(), String> {
        let ids: Vec<_> = self
            .live
            .keys()
            .filter(|id| only.map_or(true, |wanted| id.as_str() == wanted))
            .cloned()
            .collect();
        // AI/exit controls and input errors stay available even if history
        // persistence is full or failed. These requests do not append history.
        let mut first_error = self.take_control_requests(&ids);
        if self.retry_pending() {
            for id in ids {
                if !self.persistence.can_accept(PERSISTENCE_CONTROL_RESERVE) {
                    break;
                }
                match self.maintain_session(&id) {
                    Ok(true) => {}
                    Ok(false) => break,
                    Err(error) => {
                        if first_error.is_none() {
                            first_error = Some(error);
                        }
                    }
                }
            }
        }
        if !self.persistence_feedback() {
            return Err(self.last_error.clone());
        }
        match first_error {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    fn take_control_requests(&mut self, ids: &[String]) -> Option<String> {
        let mut first_error = None;
        for id in ids {
            let Some(term) = self.live.get(id) else {
                continue;
            };
            if let Some(error) = term.input_error() {
                first_error.get_or_insert_with(|| format!("Terminal input: {error}"));
            }
            match term.take_exit_request() {
                Ok(true) => self.exit_requests.push(id.clone()),
                Ok(false) => {}
                Err(error) => {
                    first_error.get_or_insert_with(|| format!("Exit request: {error}"));
                }
            }
            match term.take_ai_request() {
                Ok(Some(question)) => self.ai_queries.push(AIQuery {
                    session_id: id.clone(),
                    question,
                }),
                Ok(None) => {}
                Err(error) => {
                    first_error.get_or_insert_with(|| format!("AI request: {error}"));
                }
            }
        }
        first_error
    }

    fn maintain_session(&mut self, id: &str) -> Result<bool, String> {
        let marks = match self.live.get_mut(id) {
            Some(term) => term
                .take_command_marks()
                .map_err(|e| format!("Command timeline: {e}"))?,
            None => return Ok(true),
        };
        // Queue consumed metadata immediately; later state/request errors
        // must not discard an already-read completed command.
        if !marks.is_empty()
            && !self.enqueue(PersistenceJob::Marks {
                session: id.to_owned(),
                entries: marks,
            })
        {
            return Ok(false);
        }
        let mut state_update = None;
        let mut exited = false;
        if let Some(term) = self.live.get_mut(id) {
            if !term.remote {
                if let Ok(Some((cwd, venv))) = term.snapshot_state() {
                    if let Some(rec) = self.records.iter().find(|r| r.id == id) {
                        if rec.cwd != cwd || rec.venv != venv {
                            let mut updated = rec.clone();
                            updated.cwd = cwd;
                            updated.venv = venv;
                            state_update = Some(updated);
                        }
                    }
                }
                if term.exit_observed_polls > 0 && !self.persistence.session_pending(id) {
                    exited = term
                        ._child
                        .try_wait()
                        .map_err(|e| format!("PTY wait: {e}"))?
                        .is_some();
                }
            }
        }
        if let Some(record) = state_update {
            let accepted = self.enqueue(PersistenceJob::State(record.clone()));
            // Both accepted and backpressured jobs are now owned by the
            // queue/core, so updating the UI cache cannot lose the write.
            if let Some(cached) = self.records.iter_mut().find(|r| r.id == id) {
                *cached = record;
            }
            if !accepted {
                return Ok(false);
            }
        }
        if exited {
            if !self.enqueue(PersistenceJob::Close(id.to_owned())) {
                return Ok(false);
            }
            if let Some(record) = self.records.iter_mut().find(|r| r.id == id) {
                record.closed = true;
            }
            self.live.remove(id);
            self.disk_scroll.remove(id);
            self.invalidate_screen(id);
            self.exit_requests.retain(|pending| pending != id);
        }
        Ok(true)
    }

    /// Capture at most the reader's bounded queue per session before a normal
    /// Quit/explicit close. A continuously producing process cannot make this
    /// drain infinite. Already presented bytes are always included in the barrier.
    fn flush_pending(&mut self, only: Option<&str>) -> Result<(), String> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        self.flush_persistence_until(deadline)?;
        let ids: Vec<_> = self
            .live
            .keys()
            .filter(|id| only.map_or(true, |wanted| id.as_str() == wanted))
            .cloned()
            .collect();
        for id in ids {
            let chunk = self.take_output(&id, 512 * 1024, 64);
            if !chunk.is_empty() {
                self.enqueue(PersistenceJob::output(&id, chunk));
                self.flush_persistence_until(deadline)?;
            }
        }
        let metadata_result = self.maintain_sessions(only);
        // Even if a metadata read failed, already consumed marks/state must
        // reach disk before normal Quit returns that error.
        self.flush_persistence_until(deadline)?;
        metadata_result
    }
    fn open(&mut self, id: &str) -> Result<(), String> {
        // Finish any older async close before reopening the same stable ID.
        self.flush_persistence()?;
        if self.disk_scroll.remove(id).is_some() {
            self.invalidate_screen(id);
        }
        let record = self
            .records
            .iter_mut()
            .find(|r| r.id == id)
            .ok_or("Session not found")?;
        record.closed = false;
        self.store.upsert(record).map_err(|e| e.to_string())?;
        if !self.live.contains_key(id) {
            let remote_host = self.store.remote_host(id).map_err(|e| e.to_string())?;
            let mut term = LiveTerminal::spawn(
                record.clone(),
                30,
                100,
                self.scrollback_lines,
                remote_host.as_deref(),
                Some(&self.store.remote_origin(id).map_err(|e| e.to_string())?),
            )
            .map_err(|e| e.to_string())?;
            term.restore_scrollback(&self.store, id).map_err(|e| e.to_string())?;
            self.persistence
                .set_indexer(id, history::HistoryIndexer::default())
                .map_err(|e| e.to_string())?;
            self.install_live(id, term);
        }
        // Only a successful open makes a removed tab restorable again.
        self.store.allow_session_restore(id).map_err(|e| e.to_string())?;
        Ok(())
    }

    fn install_live(&mut self, id: &str, term: LiveTerminal) {
        self.live.insert(id.to_owned(), term);
        // This counter belongs to the core, not the PTY: reopening the same
        // session ID must never reuse a previously displayed revision.
        self.invalidate_screen(id);
    }
}

#[no_mangle]
pub extern "C" fn nia_core_new() -> *mut NiaCore {
    match Store::open().and_then(|store| {
        let records = store.list()?;
        let persistence = Persistence::new(&store)?;
        Ok((store, records, persistence))
    }) {
        Ok((store, records, persistence)) => Box::into_raw(Box::new(NiaCore {
            store,
            persistence,
            pending_persistence: None,
            screen_generations: HashMap::new(),
            next_screen_generation: 0,
            poll_cursor: 0,
            records,
            live: HashMap::new(),
            last_error: String::new(),
            scrollback_lines: 10000,
            disk_scroll: HashMap::new(),
            ai_queries: Vec::new(),
            exit_requests: Vec::new(),
        })),
        Err(e) => {
            eprintln!("Nia storage initialization failed: {e:#}");
            ptr::null_mut()
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn nia_core_free(p: *mut NiaCore) {
    if !p.is_null() {
        let _ = (*p).flush_pending(None);
        drop(Box::from_raw(p));
    }
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

/// Drain exit requests from local Zsh; the command has not been run.
#[no_mangle]
pub unsafe extern "C" fn nia_take_exit_requests(p: *mut NiaCore) -> *mut c_char {
    if p.is_null() { return to_c("[]"); }
    let core = &mut *p;
    json(&std::mem::take(&mut core.exit_requests))
}

/// Authorize and run exactly one intercepted exit line.
#[no_mangle]
pub unsafe extern "C" fn nia_confirm_exit(p: *mut NiaCore, name: *const c_char) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) { Ok(s) => s, Err(e) => return core.set_error(e) };
    match core.live.get_mut(id) {
        Some(term) => match term.approve_exit() {
            Ok(()) => 0,
            Err(e) => core.set_error(e),
        },
        None => core.set_error("Session is not running"),
    }
}

/// Read a bounded timeline only when the user opens the history panel.
/// Repair derived text/anchors first; original output and shell state are untouched.
#[no_mangle]
pub unsafe extern "C" fn nia_command_marks(p: *mut NiaCore, session: *const c_char) -> *mut c_char {
    if p.is_null() {
        return to_c("[]");
    }
    let core = &mut *p;
    let id = match text_arg(session) {
        Ok(id) => id,
        Err(_) => return to_c("[]"),
    };
    if !core.records.iter().any(|r| r.id == id) {
        return to_c("[]");
    }
    // Repair before has_anchor is queried, otherwise a recoverable raw OSC
    // marker can remain unreachable behind a disabled "View output" button.
    if let Err(error) = core.ensure_history_index(id) {
        core.set_error(error);
    }
    match core.store.recent_command_marks(id, 200) {
        Ok(entries) => json(&entries),
        Err(error) => {
            core.set_error(error);
            to_c("[]")
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn nia_sessions(p: *mut NiaCore) -> *mut c_char {
    if p.is_null() { return to_c("[]"); }
    let core = &mut *p;
    let dismissed = match core.store.dismissed_sessions() {
        Ok(ids) => ids,
        Err(error) => { core.set_error(error); return to_c("null"); }
    };
    let records: Vec<_> = core.records.iter().map(|r| SessionInfo { id: &r.id, display_name: core.store.session_title(&r.id).unwrap_or_else(|_| r.id.clone()), cwd: &r.cwd, closed: r.closed, dismissed: dismissed.contains(&r.id), venv: &r.venv, color: core.store.session_color(&r.id).unwrap_or_else(|_| "#648ACA".to_string()), remote_host: core.store.remote_host(&r.id).ok().flatten() }).collect();
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

/// Get the independently persisted layout for one native window.
#[no_mangle]
pub unsafe extern "C" fn nia_window_workspace(p: *mut NiaCore, window_id: *const c_char) -> *mut c_char {
    if p.is_null() { return to_c(""); }
    let core = &*p;
    let id = match text_arg(window_id) { Ok(v) => v, Err(_) => return to_c("") };
    if id.is_empty() || id.len() > 80 || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return to_c("");
    }
    match core.store.window_workspace_layout(id) {
        Ok(Some(layout)) => to_c(layout), _ => to_c("")
    }
}

#[no_mangle]
pub unsafe extern "C" fn nia_save_window_workspace(
    p: *mut NiaCore, window_id: *const c_char, layout: *const c_char
) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(window_id) { Ok(v) => v, Err(e) => return core.set_error(e) };
    if id.is_empty() || id.len() > 80
        || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return core.set_error("Invalid window ID");
    }
    let input = match text_arg(layout) { Ok(v) => v, Err(e) => return core.set_error(e) };
    if input.len() > 16384 { return core.set_error("Window layout too large"); }
    let value: serde_json::Value = match serde_json::from_str(input) {
        Ok(v) => v, Err(e) => return core.set_error(e)
    };
    let valid_mode = matches!(value.get("mode").and_then(|v| v.as_str()), Some("off" | "vertical" | "horizontal"));
    let valid_pane = matches!(value.get("focusedPane").and_then(|v| v.as_u64()), Some(0 | 1));
    let valid_tabs = value.get("tabs").and_then(|v| v.as_array()).is_some_and(|a|
        a.len() <= 128 && a.iter().all(|v| v.as_str().is_some_and(|id|
            core.records.iter().any(|r| r.id == id))));
    if !valid_mode || !valid_pane || !valid_tabs {
        return core.set_error("Invalid window layout");
    }
    match core.store.save_window_workspace_layout(id, input) {
        Ok(()) => 0, Err(e) => core.set_error(e)
    }
}

/// Change only the human-facing label. Never rekey a live PTY, history,
/// tmux session, tab layout or any other persistent reference.
#[no_mangle]
pub unsafe extern "C" fn nia_rename_session(
    p: *mut NiaCore, session_id: *const c_char, new_title: *const c_char
) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(session_id) { Ok(v) => v, Err(e) => return core.set_error(e) };
    let title = match text_arg(new_title) { Ok(v) => v.trim(), Err(e) => return core.set_error(e) };
    if title.is_empty() || title.len() > 96 ||
       title.chars().any(|c| c.is_control() || c == '/' || c == '\\') {
        return core.set_error("Session name must be 1–96 bytes without slashes or controls");
    }
    if !core.records.iter().any(|r| r.id == id) { return core.set_error("Session not found") }
    match core.store.set_session_title(id, title) {
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
    p: *mut NiaCore,
    name: *const c_char,
) -> c_int {
    if p.is_null() {
        return -1;
    }
    let core = &mut *p;
    let id = match text_arg(name) {
        Ok(v) => v,
        Err(e) => return core.set_error(e),
    };
    match core.store.remote_host(id) {
        Ok(Some(_)) => {}
        Ok(None) => return core.set_error("This is not a remote session"),
        Err(e) => return core.set_error(e),
    }
    // Dropping the local SSH child disconnects the client; the remote tmux
    // session continues running under the remote user account.
    if let Err(error) = core.flush_pending(Some(id)) {
        return core.set_error(error);
    }
    core.live.remove(id);
    match core.open(id) {
        Ok(()) => 0,
        Err(e) => core.set_error(e),
    }
}

/// Persist tab removal without terminating its PTY or deleting history.
#[no_mangle]
pub unsafe extern "C" fn nia_dismiss_session(p: *mut NiaCore, name: *const c_char) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) {
        Ok(id) => id,
        Err(error) => return core.set_error(error),
    };
    match core.store.dismiss_session(id) {
        Ok(()) => 0,
        Err(error) => core.set_error(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn nia_archive_session(p: *mut NiaCore, name: *const c_char) -> c_int {
    if p.is_null() {
        return -1;
    }
    let core = &mut *p;
    let id = match text_arg(name) {
        Ok(s) => s,
        Err(e) => return core.set_error(e),
    };
    if let Err(error) = core.flush_pending(Some(id)) {
        return core.set_error(error);
    }
    if let Err(e) = core.store.close(id) {
        return core.set_error(e);
    }
    if let Some(rec) = core.records.iter_mut().find(|r| r.id == id) {
        rec.closed = true;
    }
    core.live.remove(id);
    core.disk_scroll.remove(id);
    core.invalidate_screen(id);
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
            Ok(()) => {
                if len > 0 {
                    let changed = term.return_to_live();
                    let disk = core.disk_scroll.remove(id).is_some();
                    if changed || disk {
                        core.invalidate_screen(id);
                    }
                }
                0
            }, Err(e) => core.set_error(e)
        },
        None => core.set_error("Session not running"),
    }
}
/// Update the PTY window size immediately, without replaying the ANSI log.
/// The shell must see the new column count before it emits its next line.
#[no_mangle]
pub unsafe extern "C" fn nia_resize_fast(
    p: *mut NiaCore,
    name: *const c_char,
    rows: u16,
    cols: u16,
) -> c_int {
    if p.is_null() {
        return -1;
    }
    let core = &mut *p;
    let id = match text_arg(name) {
        Ok(s) => s,
        Err(e) => return core.set_error(e),
    };
    let Some(term) = core.live.get_mut(id) else {
        return core.set_error("Session not running");
    };
    let rows = rows.max(1);
    let cols = cols.max(1);
    let (current_rows, current_cols) = term.parser.screen().size();
    if current_rows.get() == rows && current_cols.get() == cols {
        return 0;
    }
    match term.resize(rows, cols) {
        // Disk history holds an absolute top row, independent of viewport
        // height. A resize must neither move that row nor return to live output.
        Ok(()) => {
            core.invalidate_screen(id);
            0
        }
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
/// Once-per-process metadata maintenance, independent of the frame cadence.
#[no_mangle]
pub unsafe extern "C" fn nia_maintain(p: *mut NiaCore) -> c_int {
    if p.is_null() {
        return -1;
    }
    match (*p).maintain() {
        Ok(()) => 0,
        Err(error) => (*p).set_error(error),
    }
}
/// Explicit normal-Quit/close barrier. Never called by the presentation timer.
#[no_mangle]
pub unsafe extern "C" fn nia_flush_pending(p: *mut NiaCore) -> c_int {
    if p.is_null() {
        return -1;
    }
    match (*p).flush_pending(None) {
        Ok(()) => 0,
        Err(error) => (*p).set_error(error),
    }
}
#[no_mangle]
pub unsafe extern "C" fn nia_screen(p: *mut NiaCore, name: *const c_char) -> *mut c_char {
    if p.is_null() { return to_c("{}"); }
    let core = &*p;
    let id = match text_arg(name) { Ok(s) => s, Err(e) => return to_c(e) };
    let Some(term) = core.live.get(id) else { return to_c("{}"); };
    let screen = term.display_screen();
    let (height,width) = screen.size();
    if let Some(state) = core.disk_scroll.get(id) {
        // Deep history: only a viewport-sized page is materialized. The original
        // VT stream remains on disk separately for lossless forensic recovery.
        let line_count = height.get() as usize;
        let lines = core
            .store
            .history_page_from(id, state.first_line, line_count)
            .unwrap_or_default();
        let mut grid = vec![];
        let padding = line_count.saturating_sub(lines.len());
        for line in lines {
            let mut cells = line
                .chars()
                .take(width.get() as usize)
                .map(|ch| CellData {
                    t: ch.to_string(),
                    fg: -1,
                    bg: -1,
                    flags: 0,
                    wide: false,
                    continuation: false,
                })
                .collect::<Vec<_>>();
            while cells.len() < width.get() as usize {
                cells.push(CellData {
                    t: " ".into(),
                    fg: -1,
                    bg: -1,
                    flags: 0,
                    wide: false,
                    continuation: false,
                });
            }
            grid.push(cells);
        }
        // Short/recent commands still begin at the top. Empty space belongs
        // below them; it must not silently select the unrelated live screen.
        for _ in 0..padding {
            grid.push(vec![
                CellData {
                    t: " ".into(),
                    fg: -1,
                    bg: -1,
                    flags: 0,
                    wide: false,
                    continuation: false
                };
                width.get() as usize
            ]);
        }
        return json(&ScreenData {
            session_id: id.to_string(),
            cells: grid,
            cursor_row: 0,
            cursor_col: 0,
            cursor_visible: false,
            // Nonzero marks explicit history mode, including a jump near the tail.
            rows: height.get(),
            cols: width.get(),
            scrollback_offset: 1,
        });
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
        rows: height.get(), cols: width.get(), scrollback_offset: term.parser.screen().scrollback() })
}

/// Compact NIA1 snapshot. The caller owns this byte slice and must release it
/// with nia_snapshot_free. Unchanged frames allocate nothing and return NULL.
#[no_mangle]
pub unsafe extern "C" fn nia_screen_snapshot(
    p: *mut NiaCore,
    name: *const c_char,
    known_revision: u64,
    out_len: *mut usize,
) -> *mut u8 {
    if out_len.is_null() {
        return ptr::null_mut();
    }
    *out_len = 0;
    if p.is_null() {
        return ptr::null_mut();
    }
    let core = &mut *p;
    let id = match text_arg(name) {
        Ok(id) => id,
        Err(error) => {
            core.set_error(error);
            return ptr::null_mut();
        }
    };
    if !core.live.contains_key(id) {
        return ptr::null_mut();
    }
    if !core.screen_generations.contains_key(id) {
        core.invalidate_screen(id);
    }
    let revision = core.screen_generations[id];
    if known_revision == revision {
        return ptr::null_mut();
    }
    match binary_screen(core, id, revision) {
        Ok(bytes) => {
            let bytes = bytes.into_boxed_slice();
            *out_len = bytes.len();
            Box::into_raw(bytes) as *mut u8
        }
        Err(error) => {
            core.set_error(error);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn nia_snapshot_free(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            bytes, len,
        )));
    }
}

fn binary_screen(core: &NiaCore, id: &str, revision: u64) -> Result<Vec<u8>, String> {
    let term = core.live.get(id).ok_or("Session not running")?;
    let screen = term.display_screen();
    let (rows, cols) = screen.size();
    let cells = usize::from(rows.get()) * usize::from(cols.get());
    if cells > 1_000_000 {
        return Err("Terminal snapshot is too large".into());
    }
    let disk = core.disk_scroll.get(id);
    let (cursor_row, cursor_col) = if disk.is_some() {
        (0, 0)
    } else {
        screen.cursor_position()
    };
    let scrollback = if disk.is_some() {
        1
    } else {
        term.parser.screen().scrollback() as u64
    };
    let mut bytes = Vec::with_capacity(32 + cells * 13);
    bytes.extend_from_slice(b"NIA1");
    bytes.extend_from_slice(&revision.to_le_bytes());
    bytes.extend_from_slice(&rows.get().to_le_bytes());
    bytes.extend_from_slice(&cols.get().to_le_bytes());
    bytes.extend_from_slice(&cursor_row.to_le_bytes());
    bytes.extend_from_slice(&cursor_col.to_le_bytes());
    bytes.extend_from_slice(&scrollback.to_le_bytes());
    bytes.push(u8::from(disk.is_none() && !screen.hide_cursor()));
    bytes.extend_from_slice(&[0; 3]);
    if let Some(state) = disk {
        let lines = core
            .store
            .history_page_from(id, state.first_line, usize::from(rows.get()))
            .map_err(|error| error.to_string())?;
        for row in 0..usize::from(rows.get()) {
            let mut chars = lines.get(row).map_or("", String::as_str).chars();
            for _ in 0..cols.get() {
                let character = chars.next().unwrap_or(' ');
                let mut utf8 = [0; 4];
                append_binary_cell(&mut bytes, -1, -1, 0, 0, character.encode_utf8(&mut utf8));
            }
        }
    } else {
        for row in 0..rows.get() {
            for col in 0..cols.get() {
                if let Some(cell) = screen.cell(row, col) {
                    let flags = (cell.bold() as u8)
                        | ((cell.dim() as u8) << 1)
                        | ((cell.italic() as u8) << 2)
                        | ((cell.underline() as u8) << 3)
                        | ((cell.inverse() as u8) << 4);
                    let width = (cell.is_wide() as u8) | ((cell.is_wide_continuation() as u8) << 1);
                    append_binary_cell(
                        &mut bytes,
                        encode_color(cell.fgcolor()),
                        encode_color(cell.bgcolor()),
                        flags,
                        width,
                        &cell.contents(),
                    );
                } else {
                    append_binary_cell(&mut bytes, -1, -1, 0, 0, "");
                }
            }
        }
    }
    Ok(bytes)
}

fn append_binary_cell(bytes: &mut Vec<u8>, fg: i32, bg: i32, flags: u8, width: u8, text: &str) {
    bytes.extend_from_slice(&fg.to_le_bytes());
    bytes.extend_from_slice(&bg.to_le_bytes());
    bytes.push(flags);
    bytes.push(width);
    bytes.extend_from_slice(&(text.len() as u16).to_le_bytes());
    bytes.extend_from_slice(text.as_bytes());
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
    if p.is_null() {
        return -1;
    }
    if !(1000..=100000).contains(&lines) {
        return (*p).set_error("Scrollback must be between 1,000 and 100,000 lines");
    }
    (*p).scrollback_lines = lines as usize;
    let ids: Vec<_> = (*p).live.keys().cloned().collect();
    for id in ids {
        (*p).invalidate_screen(&id);
    }
    0
}

/// Jump to the actual output of a completed command using its OSC 133
/// anchor. Never executes the command or mutates the running shell.
#[no_mangle]
pub unsafe extern "C" fn nia_jump_to_command(
    p: *mut NiaCore,
    session: *const c_char,
    command_id: i64,
) -> c_int {
    if p.is_null() {
        return -1;
    }
    let core = &mut *p;
    let id = match text_arg(session) {
        Ok(value) => value,
        Err(e) => return core.set_error(e),
    };
    if !core.live.contains_key(id) {
        return core.set_error("Session is not running");
    }
    if let Err(error) = core.ensure_history_index(id) {
        return core.set_error(error);
    }
    match core.store.command_start_line(id, command_id) {
        Ok(Some(first_line)) => {
            core.disk_scroll
                .insert(id.to_string(), DiskScroll { first_line });
            core.invalidate_screen(id);
            0
        }
        Ok(None) => core.set_error(
            "The original command line is not available in the retained terminal history",
        ),
        Err(e) => core.set_error(e),
    }
}

/// Positive delta scrolls into older output; negative delta returns toward live output.
#[no_mangle]
pub unsafe extern "C" fn nia_scroll_at(
    p: *mut NiaCore,
    name: *const c_char,
    delta: i32,
    row: u16,
    col: u16,
) -> c_int {
    if p.is_null() { return -1; }
    let core = &mut *p;
    let id = match text_arg(name) { Ok(s) => s, Err(e) => return core.set_error(e) };
    if let Some(term) = core.live.get_mut(id) {
        if !core.disk_scroll.contains_key(id) && term.parser.screen().scrollback() == 0 {
            if let Some(bytes) = terminal::wheel_input(term.parser.screen(), delta, row, col) {
                return match term.send(&bytes) { Ok(()) => 0, Err(e) => core.set_error(e) };
            }
        }
    }
    nia_scroll(p, name, delta)
}

#[no_mangle]
pub unsafe extern "C" fn nia_scroll(p: *mut NiaCore, name: *const c_char, delta: i32) -> c_int {
    if p.is_null() {
        return -1;
    }
    let core = &mut *p;
    let id = match text_arg(name) {
        Ok(s) => s,
        Err(e) => return core.set_error(e),
    };
    let Some(term) = core.live.get_mut(id) else {
        return core.set_error("Session not running");
    };
    let height = term.parser.screen().size().0.get() as usize;
    if let Some(state) = core.disk_scroll.get(id).copied() {
        return match core
            .store
            .history_scroll_top(id, state.first_line, delta, height)
        {
            Ok(Some(first_line)) => {
                core.disk_scroll
                    .insert(id.to_string(), DiskScroll { first_line });
                core.invalidate_screen(id);
                0
            }
            Ok(None) => {
                core.disk_scroll.remove(id);
                term.return_to_live();
                core.invalidate_screen(id);
                0
            }
            Err(error) => core.set_error(error),
        };
    }
    // Fullscreen applications own their screen. Never substitute the text
    // search index when their alternate screen has no terminal scrollback.
    if term.parser.screen().alternate_screen() {
        return 0;
    }
    let offset = term.parser.screen().scrollback();
    let next = if delta >= 0 {
        offset.saturating_add(delta as usize)
    } else {
        offset.saturating_sub(delta.unsigned_abs() as usize)
    };
    term.parser.screen_mut().set_scrollback(next);
    // The plain text command index is a separate, explicit view. Wheel
    // scrolling always uses VT cells, including attributes and empty rows.
    term.freeze_history_view();
    core.invalidate_screen(id);
    0
}

#[cfg(test)]
mod command_navigation_tests {
    use super::*;

    struct Fixture {
        core: NiaCore,
        _temp: tempfile::TempDir,
        session: CString,
        mark_id: i64,
    }
    impl Fixture {
        fn fresh(height: u16) -> Self {
            let temp = tempfile::tempdir().unwrap();
            let store = Store::for_tests(temp.path().to_path_buf()).unwrap();
            let persistence = Persistence::new(&store).unwrap();
            let term = LiveTerminal::for_history_tests(height, 80).unwrap();
            let mut live = HashMap::new();
            live.insert("test".into(), term);
            Self {
                core: NiaCore {
                    store,
                    persistence,
                    pending_persistence: None,
                    screen_generations: HashMap::from([("test".into(), 1)]),
                    next_screen_generation: 1,
                    poll_cursor: 0,
                    records: vec![SessionRecord {
                        id: "test".into(),
                        cwd: "/tmp".into(),
                        venv: None,
                        closed: false,
                    }],
                    live,
                    last_error: String::new(),
                    scrollback_lines: 100,
                    disk_scroll: HashMap::new(),
                    ai_queries: Vec::new(),
                    exit_requests: Vec::new(),
                },
                _temp: temp,
                session: CString::new("test").unwrap(),
                mark_id: 0,
            }
        }
        fn new(raw: &[u8], height: u16) -> Self {
            Self::with_log(raw, height, true)
        }
        fn with_log(raw: &[u8], height: u16, legacy_index: bool) -> Self {
            let mut fixture = Self::fresh(height);
            fixture
                .core
                .store
                .append_command_marks("test", &[(1000.5, 1, 0, "/tmp".into(), "command".into())])
                .unwrap();
            Store::append_and_sync(&mut fixture.core.store.log_file("test").unwrap(), raw).unwrap();
            if legacy_index {
                // Simulate the legacy CRLF bug while retaining its usable OSC mark.
                fixture
                    .core
                    .store
                    .append_history_lines("test", &["".into()], &[(1000.5, 1)])
                    .unwrap();
            }
            fixture.mark_id = fixture.core.store.recent_command_marks("test", 1).unwrap()[0].id;
            let term = fixture.core.live.get_mut("test").unwrap();
            for _ in 0..40 {
                term.parser.process(b"old live row\r\n");
            }
            term.parser.process(b"LIVE END");
            fixture
        }
        fn jump(&mut self) -> i32 {
            unsafe { nia_jump_to_command(&mut self.core, self.session.as_ptr(), self.mark_id) }
        }
        fn screen(&mut self) -> serde_json::Value {
            unsafe {
                let output = nia_screen(&mut self.core, self.session.as_ptr());
                let result = serde_json::from_slice(CStr::from_ptr(output).to_bytes()).unwrap();
                nia_string_free(output);
                result
            }
        }
        fn timeline(&mut self) -> serde_json::Value {
            unsafe {
                let output = nia_command_marks(&mut self.core, self.session.as_ptr());
                let result = serde_json::from_slice(CStr::from_ptr(output).to_bytes()).unwrap();
                nia_string_free(output);
                result
            }
        }
        fn rows(&mut self) -> Vec<String> {
            self.screen()["cells"]
                .as_array()
                .unwrap()
                .iter()
                .map(|row| {
                    row.as_array()
                        .unwrap()
                        .iter()
                        .map(|cell| cell["t"].as_str().unwrap())
                        .collect::<String>()
                        .trim_end()
                        .to_owned()
                })
                .collect()
        }
        fn append(&mut self, bytes: &[u8]) {
            Store::append_and_sync(&mut self.core.store.log_file("test").unwrap(), bytes).unwrap();
            let term = self.core.live.get_mut("test").unwrap();
            let lines = term.history_indexer.ingest(bytes);
            let anchors = term.history_indexer.take_anchors();
            self.core
                .store
                .append_history_lines("test", &lines, &anchors)
                .unwrap();
        }
    }
    #[test]
    fn sync_reload_adds_imports_without_replacing_live_state_or_opening_ptys() {
        let mut fixture = Fixture::fresh(4);
        fixture.core.store.upsert(&SessionRecord {
            id: "test".into(), cwd: "/stale-disk-state".into(), venv: None, closed: true,
        }).unwrap();
        fixture.core.store.upsert(&SessionRecord {
            id: "sync-import".into(), cwd: "/tmp".into(), venv: None, closed: true,
        }).unwrap();
        assert_eq!(unsafe { nia_reload_sessions(&mut fixture.core) }, 0);
        assert_eq!(unsafe { nia_reload_sessions(&mut fixture.core) }, 0);
        assert_eq!(fixture.core.records.len(), 2);
        assert_eq!(fixture.core.records[0].cwd, "/tmp");
        assert!(!fixture.core.records[0].closed);
        assert!(fixture.core.records[1].closed);
        assert_eq!(fixture.core.live.len(), 1);
        assert!(fixture.core.live.contains_key("test"));
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            for term in self.core.live.values_mut() {
                let _ = term._child.kill();
                let _ = term._child.wait();
            }
        }
    }

    #[test]
    fn restored_scrollback_has_ansi_attributes_and_a_clean_live_screen() {
        let mut fixture = Fixture::fresh(4);
        let raw = b"\x1b[38;2;12;34;56;1;3;4mold colored prompt\x1b[0m\r\n\r\nnext\r\n";
        Store::append_and_sync(&mut fixture.core.store.log_file("test").unwrap(), raw).unwrap();
        fixture.core.live.get_mut("test").unwrap().restore_scrollback(&fixture.core.store, "test").unwrap();
        assert!(fixture.rows().iter().all(String::is_empty), "old prompts must never remain live");
        assert_eq!(fixture.screen()["cursor_row"], 0);
        fixture.core.live.get_mut("test").unwrap().parser.process(b"new prompt");
        assert_eq!(fixture.rows()[0], "new prompt");
        unsafe { nia_scroll(&mut fixture.core, fixture.session.as_ptr(), 100); }
        assert_eq!(&fixture.rows()[..3], ["old colored prompt", "", "next"]);
        assert_eq!(fixture.screen()["cells"][0][0]["fg"], 0x1000000 | (12 << 16) | (34 << 8) | 56);
        assert_eq!(fixture.screen()["cells"][0][0]["flags"], 1 | 4 | 8);
    }

    #[test]
    fn background_redraw_does_not_change_the_page_being_read() {
        let mut fixture = Fixture::fresh(4);
        let term = fixture.core.live.get_mut("test").unwrap();
        for line in 0..8 {
            term.parser.process(format!("row {line}\r\n").as_bytes());
        }
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        term.rx = receiver;
        unsafe { nia_scroll(&mut fixture.core, fixture.session.as_ptr(), 1); }
        let page = fixture.rows();
        sender.send(b"\x1b[H\x1b[2Jentirely repainted\r\n".to_vec()).unwrap();
        fixture.core.refresh();
        assert_eq!(fixture.rows(), page);
        unsafe { nia_send(&mut fixture.core, fixture.session.as_ptr(), b"x".as_ptr(), 1); }
        assert!(fixture.rows().iter().any(|row| row.contains("entirely repainted")));
    }

    #[test]
    fn typing_from_explicit_command_history_returns_to_live() {
        let mut fixture = Fixture::new(b"$ command\r\n\x1b]133;C;1000.5\x07result\r\n", 4);
        assert_eq!(fixture.jump(), 0);
        unsafe { nia_send(&mut fixture.core, fixture.session.as_ptr(), b"x".as_ptr(), 1); }
        assert!(!fixture.core.disk_scroll.contains_key("test"));
        assert_eq!(fixture.screen()["scrollback_offset"], 0);
        assert!(fixture.rows().iter().any(|row| row.contains("LIVE END")));
    }

    #[test]
    fn wheel_at_oldest_row_preserves_colors_and_blank_rows() {
        let mut fixture = Fixture::fresh(4);
        let raw = b"\x1b[31;1mred\x1b[0m\r\n\r\nthird\r\nfourth\r\nfifth\r\n";
        Store::append_and_sync(&mut fixture.core.store.log_file("test").unwrap(), raw).unwrap();
        fixture.core.live.get_mut("test").unwrap().parser.process(raw);
        for _ in 0..3 {
            assert_eq!(unsafe { nia_scroll(&mut fixture.core, fixture.session.as_ptr(), 50) }, 0);
        }
        let screen = fixture.screen();
        assert_eq!(screen["cells"][0][0]["fg"], 1, "scroll must not switch to the plain text index");
        assert_eq!(screen["cells"][0][0]["flags"], 1);
        assert_eq!(&fixture.rows()[..3], ["red", "", "third"]);
    }

    #[test]
    fn typing_from_scrollback_returns_to_the_live_prompt() {
        let mut fixture = Fixture::new(b"old\r\n", 4);
        assert_eq!(unsafe { nia_scroll(&mut fixture.core, fixture.session.as_ptr(), 3) }, 0);
        let before = binary_snapshot(&mut fixture, 0).unwrap().0;
        assert_eq!(unsafe { nia_send(&mut fixture.core, fixture.session.as_ptr(), b"x".as_ptr(), 1) }, 0);
        assert_eq!(fixture.screen()["scrollback_offset"], 0);
        assert!(binary_snapshot(&mut fixture, before).is_some());
    }

    #[test]
    fn resize_while_scrolled_preserves_the_top_row() {
        let mut fixture = Fixture::fresh(4);
        for line in 0..30 {
            fixture.core.live.get_mut("test").unwrap().parser.process(format!("row {line}\r\n").as_bytes());
        }
        unsafe { nia_scroll(&mut fixture.core, fixture.session.as_ptr(), 10); }
        let top = fixture.rows()[0].clone();
        unsafe { nia_resize_fast(&mut fixture.core, fixture.session.as_ptr(), 7, 100); }
        assert_eq!(fixture.rows()[0], top);
    }

    #[test]
    fn alternate_screen_wheel_does_not_replace_the_application_with_plain_history() {
        let mut fixture = Fixture::new(b"unrelated old output\r\n", 4);
        fixture.core.live.get_mut("test").unwrap().parser.process(b"\x1b[?1049h\x1b[32mAPP");
        let before = fixture.rows();
        unsafe { nia_scroll(&mut fixture.core, fixture.session.as_ptr(), 3); }
        assert_eq!(fixture.rows(), before);
        assert_eq!(fixture.screen()["cells"][0][0]["fg"], 2);
    }

    #[test]
    fn long_command_output_starts_at_command_and_stays_there_during_resize_and_append() {
        let mut raw = String::from("earlier output\r\n$ command\r\n\x1b]133;C;1000.5\x07");
        for line in 1..=100 {
            raw.push_str(&format!("{line}\r\n"));
        }
        let mut fixture = Fixture::new(raw.as_bytes(), 10);
        assert_eq!(fixture.jump(), 0, "{}", fixture.core.last_error);
        assert_eq!(&fixture.rows()[..3], ["$ command", "1", "2"]);
        assert_eq!(
            unsafe { nia_resize_fast(&mut fixture.core, fixture.session.as_ptr(), 25, 120) },
            0
        );
        assert_eq!(&fixture.rows()[..3], ["$ command", "1", "2"]);
        fixture.append(b"background output\r\n");
        assert_eq!(&fixture.rows()[..3], ["$ command", "1", "2"]);
        assert_eq!(
            unsafe { nia_resize_fast(&mut fixture.core, fixture.session.as_ptr(), 4, 40) },
            0
        );
        assert_eq!(&fixture.rows()[..3], ["$ command", "1", "2"]);
    }

    #[test]
    fn recent_and_no_output_commands_remain_in_history_at_the_top() {
        for output in ["", "result\r\n"] {
            let raw = format!("$ command\r\n\x1b]133;C;1000.5\x07{output}");
            let mut fixture = Fixture::new(raw.as_bytes(), 10);
            assert_eq!(fixture.jump(), 0, "{}", fixture.core.last_error);
            let rows = fixture.rows();
            assert_eq!(rows[0], "$ command");
            assert!(rows.last().unwrap().is_empty(), "pad below short history");
            assert_eq!(fixture.screen()["cursor_visible"], false);
            assert_ne!(fixture.screen()["scrollback_offset"], 0);
            assert!(!rows.iter().any(|row| row.contains("LIVE END")));
        }
    }

    #[test]
    fn anchor_without_retained_command_text_is_an_error_not_a_successful_live_jump() {
        let mut fixture = Fixture::new(b"\x1b]133;C;1000.5\x07", 10);
        assert_eq!(fixture.jump(), -1);
        assert!(fixture.core.last_error.contains("original command line"));
        assert!(!fixture.core.disk_scroll.contains_key("test"));
    }

    #[test]
    fn explicit_down_scroll_returns_to_live_and_clears_vt_scrollback() {
        let mut fixture = Fixture::new(b"$ command\r\n\x1b]133;C;1000.5\x07result\r\n", 10);
        fixture
            .core
            .live
            .get_mut("test")
            .unwrap()
            .parser
            .screen_mut()
            .set_scrollback(5);
        assert_eq!(fixture.jump(), 0);
        assert_eq!(
            unsafe { nia_scroll(&mut fixture.core, fixture.session.as_ptr(), -1) },
            0
        );
        assert!(!fixture.core.disk_scroll.contains_key("test"));
        assert_eq!(fixture.core.live["test"].parser.screen().scrollback(), 0);
        assert!(fixture.rows().iter().any(|row| row.contains("LIVE END")));
    }

    #[test]
    fn explicit_history_navigation_repairs_legacy_index_and_restores_streaming_tail() {
        let mut fixture =
            Fixture::new(b"$ command\r\n\x1b]133;C;1000.5\x07result\r\npartial\r", 10);
        assert_eq!(fixture.jump(), 0);
        assert_eq!(fixture.rows()[0], "$ command");
        fixture.append(b"\n");
        assert_eq!(&fixture.rows()[..3], ["$ command", "result", "partial"]);
    }

    #[test]
    fn new_session_history_before_first_output_is_harmless() {
        let mut fixture = Fixture::fresh(10);
        assert!(!fixture.core.store.log_path("test").exists());
        assert_eq!(
            unsafe { nia_scroll(&mut fixture.core, fixture.session.as_ptr(), 3) },
            0
        );
        assert!(!fixture.core.disk_scroll.contains_key("test"));
        assert_eq!(fixture.core.live["test"].parser.screen().scrollback(), 0);
        assert_eq!(fixture.timeline(), serde_json::json!([]));
        assert!(fixture.core.last_error.is_empty());
        assert!(!fixture.core.store.log_path("test").exists());
    }

    #[test]
    fn opening_timeline_recovers_missing_anchors_before_gating_view_output() {
        let mut fixture = Fixture::with_log(
            b"$ command\r\n\x1b]133;C;1000.5\x07result\r\npartial\r",
            10,
            false,
        );
        assert!(!fixture.core.store.recent_command_marks("test", 1).unwrap()[0].has_anchor);
        let entries = fixture.timeline();
        assert_eq!(entries[0]["has_anchor"], true);
        assert_eq!(entries[0]["id"], fixture.mark_id);
        assert_eq!(fixture.jump(), 0);
        fixture.append(b"\n");
        assert_eq!(&fixture.rows()[..3], ["$ command", "result", "partial"]);
    }

    #[test]
    fn timeline_repair_error_preserves_command_metadata() {
        let mut fixture = Fixture::new(b"$ command\r\n\x1b]133;C;1000.5\x07", 10);
        std::fs::remove_file(fixture.core.store.log_path("test")).unwrap();
        let entries = fixture.timeline();
        assert_eq!(entries[0]["id"], fixture.mark_id);
        assert_eq!(entries[0]["command"], "command");
        assert_eq!(entries[0]["has_anchor"], true);
        assert!(fixture
            .core
            .last_error
            .contains("original terminal log is unavailable"));
    }

    fn binary_snapshot(fixture: &mut Fixture, known: u64) -> Option<(u64, Vec<u8>)> {
        unsafe {
            let mut len = 0;
            let data =
                nia_screen_snapshot(&mut fixture.core, fixture.session.as_ptr(), known, &mut len);
            if data.is_null() {
                assert_eq!(len, 0);
                return None;
            }
            let bytes = std::slice::from_raw_parts(data, len).to_vec();
            nia_snapshot_free(data, len);
            let revision = u64::from_le_bytes(bytes[4..12].try_into().unwrap());
            Some((revision, bytes))
        }
    }

    #[test]
    fn echoed_input_is_visible_while_the_persistence_worker_is_blocked() {
        let mut fixture = Fixture::fresh(10);
        let (sender, receiver) = std::sync::mpsc::sync_channel(64);
        fixture.core.live.get_mut("test").unwrap().rx = receiver;
        let initial = binary_snapshot(&mut fixture, 0).unwrap().0;
        fixture.core.persistence.block_for_tests(true);
        sender.send(b"typed now".to_vec()).unwrap();
        fixture.core.refresh();
        assert!(fixture.core.live["test"]
            .parser
            .screen()
            .contents()
            .contains("typed now"));
        assert!(fixture.core.persistence.session_pending("test"));
        assert!(binary_snapshot(&mut fixture, initial).is_some());
        assert_eq!(
            std::fs::metadata(fixture.core.store.log_path("test")).map_or(0, |m| m.len()),
            0
        );
        fixture.core.persistence.block_for_tests(false);
        fixture.core.flush_persistence().unwrap();
        assert_eq!(
            std::fs::read(fixture.core.store.log_path("test")).unwrap(),
            b"typed now"
        );
    }

    #[test]
    fn committed_disk_history_invalidates_a_snapshot_taken_before_the_commit() {
        let mut fixture = Fixture::new(b"$ command\r\n\x1b]133;C;1000.5\x07first\r\n", 10);
        assert_eq!(fixture.jump(), 0);
        let (sender, receiver) = std::sync::mpsc::sync_channel(64);
        fixture.core.live.get_mut("test").unwrap().rx = receiver;
        fixture.core.persistence.block_for_tests(true);
        sender.send(b"second\r\n".to_vec()).unwrap();
        fixture.core.refresh();
        let before_commit = binary_snapshot(&mut fixture, 0).unwrap().0;
        assert!(!fixture.rows().iter().any(|row| row == "second"));
        fixture.core.persistence.block_for_tests(false);
        fixture.core.flush_persistence().unwrap();
        fixture.core.refresh();
        assert!(binary_snapshot(&mut fixture, before_commit).is_some());
        assert_eq!(&fixture.rows()[..3], ["$ command", "first", "second"]);
    }

    #[test]
    fn revisions_skip_idle_frames_and_change_for_resize_scroll_and_live_reopen() {
        let mut fixture = Fixture::new(b"$ command\r\n\x1b]133;C;1000.5\x07result\r\n", 10);
        let original = binary_snapshot(&mut fixture, 0).unwrap().0;
        fixture.core.refresh();
        assert!(binary_snapshot(&mut fixture, original).is_none());
        assert_eq!(
            unsafe { nia_resize_fast(&mut fixture.core, fixture.session.as_ptr(), 12, 90) },
            0
        );
        let resized = binary_snapshot(&mut fixture, original).unwrap().0;
        assert_eq!(fixture.jump(), 0);
        let history = binary_snapshot(&mut fixture, resized).unwrap().0;
        fixture.core.open("test").unwrap();
        assert!(!fixture.core.disk_scroll.contains_key("test"));
        let live = binary_snapshot(&mut fixture, history).unwrap().0;
        assert_eq!(
            unsafe { nia_scroll(&mut fixture.core, fixture.session.as_ptr(), 1) },
            0
        );
        assert!(binary_snapshot(&mut fixture, live).is_some());
    }

    #[test]
    fn same_session_id_gets_a_new_revision_after_close_and_reopen() {
        let mut fixture = Fixture::fresh(10);
        let original = binary_snapshot(&mut fixture, 0).unwrap().0;
        fixture
            .core
            .live
            .get_mut("test")
            .unwrap()
            ._child
            .kill()
            .unwrap();
        fixture
            .core
            .live
            .get_mut("test")
            .unwrap()
            ._child
            .wait()
            .unwrap();
        assert_eq!(
            unsafe { nia_archive_session(&mut fixture.core, fixture.session.as_ptr()) },
            0
        );
        let terminal = LiveTerminal::for_history_tests(10, 80).unwrap();
        fixture.core.install_live("test", terminal);
        let reopened = binary_snapshot(&mut fixture, original).unwrap().0;
        assert!(reopened > original);
    }

    #[test]
    fn dismissed_tab_survives_reload_without_terminating_pty_or_erasing_history() {
        let mut fixture = Fixture::new(b"preserved history\r\n", 10);
        fixture.core.store.upsert(&fixture.core.records[0]).unwrap();
        let generation = fixture.core.screen_generations["test"];
        assert_eq!(unsafe { nia_dismiss_session(&mut fixture.core, fixture.session.as_ptr()) }, 0);
        assert_eq!(unsafe { nia_dismiss_session(&mut fixture.core, fixture.session.as_ptr()) }, 0);
        assert!(fixture.core.live.contains_key("test"));
        assert_eq!(fixture.core.screen_generations["test"], generation);
        assert!(!fixture.core.records[0].closed);

        // A later background shell-state write must not undo tab removal.
        fixture.core.store.update_shell_state(&fixture.core.records[0]).unwrap();
        let reloaded = Store::for_tests(fixture._temp.path().to_path_buf()).unwrap();
        assert!(reloaded.dismissed_sessions().unwrap().contains("test"));
        assert!(!reloaded.list().unwrap()[0].closed);
        assert_eq!(std::fs::read(reloaded.log_path("test")).unwrap(), b"preserved history\r\n");
        let payload = unsafe { CString::from_raw(nia_sessions(&mut fixture.core)) };
        let entries: serde_json::Value = serde_json::from_str(payload.to_str().unwrap()).unwrap();
        assert_eq!(entries[0]["dismissed"], true);

        assert_eq!(unsafe { nia_open_session(&mut fixture.core, fixture.session.as_ptr()) }, 0);
        assert!(!reloaded.dismissed_sessions().unwrap().contains("test"));
        assert_eq!(fixture.core.screen_generations["test"], generation);
        assert!(fixture.core.live.contains_key("test"));
    }

    #[test]
    fn dismiss_failure_does_not_kill_session_or_return_restorable_metadata() {
        let mut fixture = Fixture::fresh(10);
        fixture.core.store.upsert(&fixture.core.records[0]).unwrap();
        fixture.core.store.conn.execute_batch("DROP TABLE dismissed_sessions").unwrap();
        assert_ne!(unsafe { nia_dismiss_session(&mut fixture.core, fixture.session.as_ptr()) }, 0);
        assert!(fixture.core.live.contains_key("test"));
        let payload = unsafe { CString::from_raw(nia_sessions(&mut fixture.core)) };
        assert_eq!(payload.to_str().unwrap(), "null");
        assert!(!fixture.core.last_error.is_empty());
    }

    #[test]
    fn normal_quit_flush_captures_the_bounded_reader_tail() {
        let mut fixture = Fixture::fresh(10);
        let (sender, receiver) = std::sync::mpsc::sync_channel(64);
        fixture.core.live.get_mut("test").unwrap().rx = receiver;
        sender.send(b"first\r\n".to_vec()).unwrap();
        sender.send(b"last before quit\r\n".to_vec()).unwrap();
        assert_eq!(unsafe { nia_flush_pending(&mut fixture.core) }, 0);
        assert_eq!(
            std::fs::read(fixture.core.store.log_path("test")).unwrap(),
            b"first\r\nlast before quit\r\n"
        );
        assert_eq!(
            fixture.core.store.history_page_from("test", 0, 10).unwrap(),
            ["first", "last before quit"]
        );
    }

    #[test]
    fn output_reserves_metadata_capacity_and_full_history_keeps_exit_and_ai_controls() {
        let mut fixture = Fixture::fresh(10);
        let (sender, receiver) = std::sync::mpsc::sync_channel(64);
        fixture.core.live.get_mut("test").unwrap().rx = receiver;
        fixture.core.persistence.block_for_tests(true);

        let background = "background";
        let payload_len = persistence::QUEUE_BYTES
            - PERSISTENCE_CONTROL_RESERVE
            - persistence::JOB_OVERHEAD
            - background.len();
        assert!(fixture
            .core
            .enqueue(PersistenceJob::output(background, vec![b' '; payload_len],)));
        sender.send(b"typed later\r\n".to_vec()).unwrap();
        fixture.core.refresh();
        assert!(fixture.core.live["test"]
            .parser
            .screen()
            .contents()
            .is_empty());
        assert!(fixture
            .core
            .persistence
            .can_accept(PERSISTENCE_CONTROL_RESERVE));

        // Even if metadata uses the final reserve and a consumed job must be
        // retained by the core, protected exit and AI requests are independent.
        let final_len = PERSISTENCE_CONTROL_RESERVE - persistence::JOB_OVERHEAD - background.len();
        assert!(fixture
            .core
            .enqueue(PersistenceJob::output(background, vec![b' '; final_len],)));
        assert!(!fixture
            .core
            .enqueue(PersistenceJob::output("deferred", b"kept\r\n".to_vec())));
        let ai_path = fixture._temp.path().join("ai-request");
        let exit_path = fixture._temp.path().join("exit-request");
        std::fs::write(&ai_path, b"explain this command").unwrap();
        std::fs::write(&exit_path, b"exit").unwrap();
        fixture
            .core
            .live
            .get_mut("test")
            .unwrap()
            .request_paths_for_tests(ai_path.clone(), exit_path.clone());
        fixture.core.maintain().unwrap();
        assert_eq!(fixture.core.exit_requests, ["test"]);
        assert_eq!(fixture.core.ai_queries.len(), 1);
        assert_eq!(fixture.core.ai_queries[0].session_id, "test");
        assert_eq!(fixture.core.ai_queries[0].question, "explain this command");
        assert!(!ai_path.exists());
        assert!(!exit_path.exists());
        assert!(fixture.core.pending_persistence.is_some());

        fixture.core.persistence.block_for_tests(false);
        fixture.core.flush_pending(None).unwrap();
        assert!(fixture.core.pending_persistence.is_none());
        assert_eq!(
            std::fs::read(fixture.core.store.log_path("test")).unwrap(),
            b"typed later\r\n"
        );
        assert_eq!(
            std::fs::read(fixture.core.store.log_path("deferred")).unwrap(),
            b"kept\r\n"
        );
        assert_eq!(
            std::fs::metadata(fixture.core.store.log_path(background))
                .unwrap()
                .len(),
            (payload_len + final_len) as u64
        );
    }
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
