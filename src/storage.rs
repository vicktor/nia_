// SPDX-License-Identifier: MPL-2.0
use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::{fs::{self, File, OpenOptions}, io::{Read, Write}, path::PathBuf};
use crate::history::HistoryIndexer;

const HISTORY_INDEX_VERSION: i64 = 2;

#[derive(Debug, Clone)]
pub struct SessionRecord {
    pub id: String,
    pub cwd: String,
    pub venv: Option<String>,
    pub closed: bool,
}

#[derive(Debug, serde::Serialize)]
pub struct CommandMark {
    pub id: i64,
    pub started_at: f64,
    pub duration_ms: i64,
    pub exit_code: i64,
    pub cwd: String,
    pub command: String,
    pub repeat_count: i64,
    pub has_anchor: bool,
}

pub struct Store {
    conn: Connection,
    home: PathBuf,
}

impl Store {
    pub fn open() -> Result<Self> {
        let base = dirs::data_local_dir()
            .context("no local data directory")?
            .join("ember-terminal");
        Self::open_at(base)
    }

    fn open_at(base: PathBuf) -> Result<Self> {
        fs::create_dir_all(base.join("logs"))?;
        let conn = Connection::open(base.join("sessions.sqlite3"))?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS sessions (
              id TEXT PRIMARY KEY,
              cwd TEXT NOT NULL,
              venv TEXT,
              closed INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            CREATE TABLE IF NOT EXISTS remote_sessions (
              session_id TEXT PRIMARY KEY REFERENCES sessions(id),
              ssh_host TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS session_colors (
              session_id TEXT PRIMARY KEY, color TEXT NOT NULL
            );
            -- Display labels deliberately live apart from internal IDs:
            -- PTYs, logs, command marks, SSH/tmux and workspaces keep using id.
            CREATE TABLE IF NOT EXISTS session_titles (
              session_id TEXT PRIMARY KEY REFERENCES sessions(id),
              title TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS history_lines (
              session_id TEXT NOT NULL,
              line_no INTEGER NOT NULL,
              text TEXT NOT NULL,
              PRIMARY KEY(session_id, line_no)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS history_counters (
              session_id TEXT PRIMARY KEY,
              next_line INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS command_marks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL,
              started_at REAL NOT NULL,
              duration_ms INTEGER NOT NULL,
              exit_code INTEGER NOT NULL,
              cwd TEXT NOT NULL,
              command TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS command_marks_recent
              ON command_marks(session_id, id DESC);
            CREATE TABLE IF NOT EXISTS command_anchors (
              session_id TEXT NOT NULL,
              started_at REAL NOT NULL,
              line_no INTEGER NOT NULL,
              PRIMARY KEY(session_id, started_at)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS history_index_versions (
              session_id TEXT PRIMARY KEY,
              version INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS preferences (
              key TEXT PRIMARY KEY, value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS actions (
              id TEXT PRIMARY KEY,
              command TEXT NOT NULL,
              session_id TEXT,
              confirm INTEGER NOT NULL DEFAULT 1
            );")?;
        // Index only non-empty transcript lines for deep-history navigation.
        // Existing sessions and their raw ANSI logs are unchanged.
        conn.execute_batch("CREATE INDEX IF NOT EXISTS history_readable_idx ON history_lines(session_id, line_no) WHERE TRIM(text) <> '';")?;
        // Migration: preserve existing row creation order rather than updated_at.
        let has_order = {
            let mut columns = conn.prepare("PRAGMA table_info(sessions)")?;
            let names = columns.query_map([], |row| row.get::<_, String>(1))?;
            names.collect::<rusqlite::Result<Vec<_>>>()?.iter().any(|name| name == "sort_order")
        };
        if !has_order {
            conn.execute_batch("ALTER TABLE sessions ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0; UPDATE sessions SET sort_order=rowid;")?;
        }
        Ok(Self { conn, home: base })
    }

    #[cfg(test)]
    pub(crate) fn for_tests(base: PathBuf) -> Result<Self> {
        Self::open_at(base)
    }

    /// A separate connection is owned exclusively by the persistence thread.
    /// WAL readers can continue to inspect committed history while it writes.
    pub(crate) fn persistence_connection(&self) -> Result<Self> {
        Self::open_at(self.home.clone())
    }

    /// Background state updates must never reopen an archived session.
    pub(crate) fn update_shell_state(&self, record: &SessionRecord) -> Result<()> {
        self.conn.execute(
            "UPDATE sessions SET cwd=?2, venv=?3, updated_at=CURRENT_TIMESTAMP WHERE id=?1",
            params![record.id, record.cwd, record.venv],
        )?;
        Ok(())
    }

    pub fn remote_host(&self, id: &str) -> Result<Option<String>> {
        self.conn.query_row("SELECT ssh_host FROM remote_sessions WHERE session_id=?1", [id], |r| r.get(0))
            .optional().map_err(Into::into)
    }

    pub fn set_remote_host(&self, id: &str, host: &str) -> Result<()> {
        self.conn.execute("INSERT INTO remote_sessions(session_id,ssh_host) VALUES (?1,?2) \
            ON CONFLICT(session_id) DO UPDATE SET ssh_host=excluded.ssh_host", params![id,host])?;
        Ok(())
    }

    // Separate table preserves the old sessions schema and backup compatibility.
    pub fn session_title(&self, id: &str) -> Result<String> {
        let title: Option<String> = self.conn.query_row(
            "SELECT title FROM session_titles WHERE session_id=?1", [id], |r| r.get(0)
        ).optional()?;
        Ok(title.unwrap_or_else(|| id.to_owned()))
    }

    pub fn set_session_title(&self, id: &str, title: &str) -> Result<()> {
        // A name must not ambiguously refer to another session. Compare
        // case-insensitively against *both* stable IDs and display names.
        let exists: i64 = self.conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM sessions s
              LEFT JOIN session_titles t ON t.session_id=s.id
              WHERE s.id<>?1 AND
                (s.id=?2 COLLATE NOCASE OR COALESCE(t.title,s.id)=?2 COLLATE NOCASE))",
            params![id,title], |r| r.get(0)
        )?;
        if exists != 0 { anyhow::bail!("Another session already has that name") }
        let updated = self.conn.execute(
            "UPDATE sessions SET updated_at=CURRENT_TIMESTAMP WHERE id=?1", [id]
        )?;
        if updated == 0 { anyhow::bail!("Session not found") }
        self.conn.execute(
            "INSERT INTO session_titles(session_id,title) VALUES (?1,?2)
             ON CONFLICT(session_id) DO UPDATE SET title=excluded.title",
            params![id,title]
        )?;
        Ok(())
    }

    pub fn session_color(&self, id: &str) -> Result<String> {
        let value: Option<String> = self.conn.query_row(
            "SELECT color FROM session_colors WHERE session_id=?1", [id], |r| r.get(0)
        ).optional()?;
        Ok(value.unwrap_or_else(|| "#648ACA".to_owned()))
    }

    pub fn set_session_color(&self, id: &str, color: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO session_colors(session_id,color) VALUES (?1,?2) ON CONFLICT(session_id) DO UPDATE SET color=excluded.color",
            params![id, color]
        )?;
        Ok(())
    }

    // Kept for the legacy egui binary; the native cdylib has its own settings UI.
    #[allow(dead_code)]
    pub fn opacity(&self) -> Result<f32> {
        let value: Option<String> = self.conn.query_row(
            "SELECT value FROM preferences WHERE key='opacity'", [], |r| r.get(0)
        ).optional()?;
        Ok(value.and_then(|v| v.parse::<f32>().ok()).unwrap_or(1.0).clamp(0.2, 1.0))
    }

    // Kept for the legacy egui binary; the native cdylib has its own settings UI.
    #[allow(dead_code)]
    pub fn preference_bool(&self, key: &str, fallback: bool) -> Result<bool> {
        let raw: Option<String> = self.conn.query_row(
            "SELECT value FROM preferences WHERE key=?1", [key], |r| r.get(0)
        ).optional()?;
        Ok(raw.and_then(|s| s.parse().ok()).unwrap_or(fallback))
    }

    // Kept for the legacy egui binary; the native cdylib has its own settings UI.
    #[allow(dead_code)]
    pub fn preference_u8(&self, key: &str, fallback: u8) -> Result<u8> {
        let raw: Option<String> = self.conn.query_row(
            "SELECT value FROM preferences WHERE key=?1", [key], |r| r.get(0)
        ).optional()?;
        Ok(raw.and_then(|s| s.parse().ok()).unwrap_or(fallback))
    }

    // Kept for the legacy egui binary; the native cdylib has its own settings UI.
    #[allow(dead_code)]
    pub fn set_preference(&self, key: &str, value: String) -> Result<()> {
        self.conn.execute(
            "INSERT INTO preferences(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![key,value]
        )?;
        Ok(())
    }

    // Kept for the legacy egui binary; the native cdylib has its own settings UI.
    #[allow(dead_code)]
    pub fn set_opacity(&self, opacity: f32) -> Result<()> {
        self.conn.execute("INSERT INTO preferences(key,value) VALUES ('opacity',?1) \
            ON CONFLICT(key) DO UPDATE SET value=excluded.value", [opacity.clamp(0.2,1.0).to_string()])?;
        Ok(())
    }

    /// Single SQLite record for the entire workspace. The backup already includes
    /// the preferences table, so restores carry the layout across Macs.
    pub fn workspace_layout(&self) -> Result<Option<String>> {
        self.conn.query_row(
            "SELECT value FROM preferences WHERE key='workspace_layout_v1'",
            [], |row| row.get(0)
        ).optional().map_err(Into::into)
    }

    pub fn save_workspace_layout(&self, layout: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO preferences(key,value) VALUES ('workspace_layout_v1',?1) \
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [layout],
        )?;
        Ok(())
    }

    /// A workspace layout belongs to one native macOS window.
    pub fn window_workspace_layout(&self, id: &str) -> Result<Option<String>> {
        let key = format!("workspace_window_v1:{id}");
        self.conn.query_row("SELECT value FROM preferences WHERE key=?1",
            [key], |r| r.get(0)).optional().map_err(Into::into)
    }

    pub fn save_window_workspace_layout(&self, id: &str, layout: &str) -> Result<()> {
        let key = format!("workspace_window_v1:{id}");
        self.conn.execute(
            "INSERT INTO preferences(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![key,layout],
        )?;
        Ok(())
    }

    pub fn list(&self) -> Result<Vec<SessionRecord>> {
        let mut stmt = self.conn.prepare("SELECT id, cwd, venv, closed FROM sessions ORDER BY sort_order ASC, rowid ASC")?;
        let rows = stmt.query_map([], |r| Ok(SessionRecord {
            id: r.get(0)?, cwd: r.get(1)?, venv: r.get(2)?, closed: r.get::<_, i64>(3)? != 0
        }))?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }

    pub fn upsert(&self, session: &SessionRecord) -> Result<()> {
        self.conn.execute("INSERT INTO sessions(id,cwd,venv,closed,sort_order) VALUES (?1,?2,?3,?4,(SELECT COALESCE(MAX(sort_order),0)+1 FROM sessions))
          ON CONFLICT(id) DO UPDATE SET cwd=excluded.cwd,venv=excluded.venv,closed=excluded.closed,updated_at=CURRENT_TIMESTAMP",
          params![session.id, session.cwd, session.venv, session.closed as i64])?;
        Ok(())
    }

    pub fn move_session(&mut self, source: &str, target: &str) -> Result<()> {
        let mut order: Vec<String> = self.list()?.into_iter().map(|record| record.id).collect();
        let Some(from) = order.iter().position(|id| id == source) else { anyhow::bail!("Unknown source session"); };
        if !order.iter().any(|id| id == target) { anyhow::bail!("Unknown target session"); }
        let moved = order.remove(from);
        let to = order.iter().position(|id| id == target).expect("target checked");
        order.insert(to, moved);
        let tx = self.conn.transaction()?;
        for (i, id) in order.iter().enumerate() {
            tx.execute("UPDATE sessions SET sort_order=?1 WHERE id=?2", params![i as i64 + 1,id])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Reorder with an explicit insertion edge. This is one SQLite transaction.
    pub fn move_session_relative(&mut self, source: &str, target: &str, after: bool) -> Result<()> {
        if source == target { return Ok(()); }
        let mut order: Vec<String> = self.list()?.into_iter().map(|s| s.id).collect();
        let source_index = order.iter().position(|id| id == source)
            .ok_or_else(|| anyhow::anyhow!("Unknown source session"))?;
        order.remove(source_index);
        let target_index = order.iter().position(|id| id == target)
            .ok_or_else(|| anyhow::anyhow!("Unknown target session"))?;
        order.insert(target_index + usize::from(after), source.to_owned());
        let tx = self.conn.transaction()?;
        for (i, id) in order.iter().enumerate() {
            tx.execute("UPDATE sessions SET sort_order=?1 WHERE id=?2", params![i as i64 + 1, id])?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn close(&self, id: &str) -> Result<()> {
        self.conn.execute("UPDATE sessions SET closed=1,updated_at=CURRENT_TIMESTAMP WHERE id=?1", [id])?;
        Ok(())
    }

    // Internal path names are not derived directly from user input.
    pub(crate) fn log_path(&self, id: &str) -> PathBuf {
        let mut key = String::with_capacity(id.len() * 2);
        for b in id.bytes() { key.push_str(&format!("{b:02x}")); }
        self.home.join("logs").join(format!("{key}.bin"))
    }

    pub fn log_file(&self, id: &str) -> Result<File> {
        Ok(OpenOptions::new().create(true).append(true).open(self.log_path(id))?)
    }

    // Indexed text-only transcript, separate from the original ANSI byte log.
    // per-session line_no paging uses the index instead of OFFSET and does not load the
    // entire transcript into memory. Output may contain secrets: treat this DB
    // as confidential, just as the raw log is.
    /// Completed command metadata, indexed separately from VT and shell history.
    pub fn append_command_marks(&mut self, session: &str,
        entries: &[(f64, i64, i64, String, String)]) -> Result<()> {
        if entries.is_empty() { return Ok(()) }
        let tx = self.conn.transaction()?;
        {
            let mut insert = tx.prepare(
                "INSERT INTO command_marks(session_id, started_at, duration_ms, exit_code, cwd, command)                  VALUES(?1, ?2, ?3, ?4, ?5, ?6)"
            )?;
            for (started, duration, exit, cwd, command) in entries {
                insert.execute(params![session, started, duration, exit, cwd, command])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Return one row per exact command for this session. The representative
    /// row is always the most recent execution; older executions contribute
    /// only to repeat_count. This is an on-demand query, never a poll task.
    /// One row per command text, using its latest execution. Anchors are
    /// explicit OSC 133 events, not guesses derived from matching output.
    pub fn recent_command_marks(&self, session: &str, limit: usize) -> Result<Vec<CommandMark>> {
        let mut statement = self.conn.prepare(
            "WITH ranked AS (
                SELECT id, started_at, duration_ms, exit_code, cwd, command,
                       ROW_NUMBER() OVER (PARTITION BY command ORDER BY id DESC) AS rn,
                       COUNT(*) OVER (PARTITION BY command) AS repeat_count
                FROM command_marks WHERE session_id=?1
             )
             SELECT r.id, r.started_at, r.duration_ms, r.exit_code, r.cwd,
                    r.command, r.repeat_count, (a.line_no IS NOT NULL)
             FROM ranked r LEFT JOIN command_anchors a
                 ON a.session_id=?1 AND a.started_at=r.started_at
             WHERE r.rn=1 ORDER BY r.id DESC LIMIT ?2"
        )?;
        let rows = statement.query_map(params![session, limit.min(250) as i64], |row| {
            Ok(CommandMark {
                id: row.get(0)?, started_at: row.get(1)?,
                duration_ms: row.get(2)?, exit_code: row.get(3)?,
                cwd: row.get(4)?, command: row.get(5)?,
                repeat_count: row.get(6)?, has_anchor: row.get::<_,i64>(7)? != 0,
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }

    /// Anchor position is the absolute raw history line number. We commit
    /// emitted lines and anchors in the same transaction so a crash cannot
    /// make the two disagree.
    pub fn append_history_lines(&mut self, id: &str, lines: &[String],
        anchors: &[(f64, usize)]) -> Result<()> {
        if lines.is_empty() && anchors.is_empty() { return Ok(()); }
        let tx = self.conn.transaction()?;
        tx.execute("INSERT INTO history_counters(session_id,next_line) VALUES (?1,0) ON CONFLICT(session_id) DO NOTHING", [id])?;
        let next: i64 = tx.query_row("SELECT next_line FROM history_counters WHERE session_id=?1",[id],|r|r.get(0))?;
        {
            let mut stmt = tx.prepare("INSERT INTO history_lines(session_id,line_no,text) VALUES(?1,?2,?3)")?;
            for (i,line) in lines.iter().enumerate() { stmt.execute(params![id,next+i as i64,line])?; }
        }
        {
            let mut stmt = tx.prepare(
                "INSERT OR IGNORE INTO command_anchors(session_id,started_at,line_no) VALUES (?1,?2,?3)"
            )?;
            for (started,offset) in anchors {
                stmt.execute(params![id, started, next + *offset as i64])?;
            }
        }
        tx.execute("UPDATE history_counters SET next_line=?2 WHERE session_id=?1", params![id,next+lines.len() as i64])?;
        tx.commit()?;
        Ok(())
    }

    /// Repair the old CRLF-erasing index only when a session's history is used.
    /// Derived rows and their version change atomically; command IDs and the
    /// original byte log never change. The returned parser retains the partial
    /// last line/escape so a live session can continue at this exact log boundary.
    pub fn ensure_history_index(&mut self, session: &str) -> Result<Option<HistoryIndexer>> {
        let version: Option<i64> = self
            .conn
            .query_row(
                "SELECT version FROM history_index_versions WHERE session_id=?1",
                [session],
                |row| row.get(0),
            )
            .optional()?;
        if version.is_some_and(|version| version >= HISTORY_INDEX_VERSION) {
            return Ok(None);
        }

        // A new PTY has no log until its first output is flushed. Leave that
        // session unversioned so its first real history use can still repair.
        // Missing/empty raw data must never erase an existing derived index.
        let mut log = match File::open(self.log_path(session)) {
            Ok(log) => log,
            Err(error)
                if error.kind() == std::io::ErrorKind::NotFound
                    && !self.has_history_index_data(session)? =>
            {
                return Ok(None)
            }
            Err(error) => {
                return Err(error)
                    .context("Cannot repair history: original terminal log is unavailable")
            }
        };
        let metadata = log.metadata()?;
        anyhow::ensure!(
            metadata.is_file(),
            "Cannot repair history: original terminal log is not a file"
        );
        let remaining = metadata.len();
        if remaining == 0 {
            anyhow::ensure!(
                !self.has_history_index_data(session)?,
                "Cannot repair history: original terminal log is empty"
            );
            return Ok(None);
        }
        self.rebuild_history_index(session, &mut log, remaining)
            .map(Some)
    }

    fn has_history_index_data(&self, session: &str) -> Result<bool> {
        self.conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM history_lines WHERE session_id=?1)
                 OR EXISTS(SELECT 1 FROM command_anchors WHERE session_id=?1)
                 OR EXISTS(SELECT 1 FROM history_counters WHERE session_id=?1)",
                [session],
                |row| row.get(0),
            )
            .map_err(Into::into)
    }

    fn rebuild_history_index(
        &mut self,
        session: &str,
        log: &mut impl Read,
        mut remaining: u64,
    ) -> Result<HistoryIndexer> {
        let tx = self.conn.transaction()?;
        tx.execute("DELETE FROM history_lines WHERE session_id=?1", [session])?;
        tx.execute("DELETE FROM command_anchors WHERE session_id=?1", [session])?;
        let mut indexer = HistoryIndexer::default();
        let mut next_line: i64 = 0;
        {
            let mut insert_line =
                tx.prepare("INSERT INTO history_lines(session_id,line_no,text) VALUES(?1,?2,?3)")?;
            let mut insert_anchor = tx.prepare("INSERT OR IGNORE INTO command_anchors(session_id,started_at,line_no) VALUES(?1,?2,?3)")?;
            let mut chunk = [0u8; 64 * 1024];
            while remaining > 0 {
                let wanted = remaining.min(chunk.len() as u64) as usize;
                let count = log.read(&mut chunk[..wanted])?;
                anyhow::ensure!(count > 0, "Terminal log changed while repairing history");
                remaining -= count as u64;
                let lines = indexer.ingest(&chunk[..count]);
                let anchors = indexer.take_anchors();
                for (offset, line) in lines.iter().enumerate() {
                    insert_line.execute(params![session, next_line + offset as i64, line])?;
                }
                for (started, offset) in anchors {
                    insert_anchor.execute(params![session, started, next_line + offset as i64])?;
                }
                next_line += lines.len() as i64;
            }
        }
        tx.execute("INSERT INTO history_counters(session_id,next_line) VALUES(?1,?2) ON CONFLICT(session_id) DO UPDATE SET next_line=excluded.next_line", params![session,next_line])?;
        tx.execute("INSERT INTO history_index_versions(session_id,version) VALUES(?1,?2) ON CONFLICT(session_id) DO UPDATE SET version=excluded.version", params![session,HISTORY_INDEX_VERSION])?;
        tx.commit()?;
        Ok(indexer)
    }

    /// OSC 133 C is emitted after the echoed command. Find that preceding
    /// readable row directly, without converting it to an offset from the end.
    pub fn command_start_line(&self, session: &str, mark_id: i64) -> Result<Option<i64>> {
        let line: Option<i64> = self
            .conn
            .query_row(
                "SELECT a.line_no FROM command_marks m
             JOIN command_anchors a ON a.session_id=m.session_id AND a.started_at=m.started_at
             WHERE m.session_id=?1 AND m.id=?2",
                params![session, mark_id],
                |r| r.get(0),
            )
            .optional()?;
        let Some(line) = line else { return Ok(None) };
        self.conn.query_row(
            "SELECT line_no FROM history_lines WHERE session_id=?1 AND line_no<?2 AND TRIM(text)<>'' ORDER BY line_no DESC LIMIT 1",
            params![session,line], |row| row.get(0)
        ).optional().map_err(Into::into)
    }

    #[cfg(test)]
    pub fn history_visible_count(&self, id: &str) -> Result<u64> {
        let total: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM history_lines WHERE session_id=?1 AND TRIM(text) <> ''",
            [id],
            |row| row.get(0),
        )?;
        Ok(total.max(0) as u64)
    }

    /// Keyset paging keeps the chosen top row fixed while new output arrives
    /// and the viewport changes. No transcript-wide count is needed to render.
    pub fn history_page_from(
        &self,
        id: &str,
        first_line: i64,
        count: usize,
    ) -> Result<Vec<String>> {
        let count = count.clamp(1, u16::MAX as usize);
        let mut stmt = self.conn.prepare(
            "SELECT text FROM history_lines WHERE session_id=?1 AND line_no>=?2 AND TRIM(text) <> '' \
             ORDER BY line_no ASC LIMIT ?3")?;
        let items = stmt
            .query_map(params![id, first_line, count as i64], |row| {
                row.get::<_, String>(0)
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(items)
    }

    fn history_first_line(&self, id: &str) -> Result<Option<i64>> {
        self.conn.query_row("SELECT line_no FROM history_lines WHERE session_id=?1 AND TRIM(text)<>'' ORDER BY line_no ASC LIMIT 1",
            [id], |row| row.get(0)).optional().map_err(Into::into)
    }

    /// Used only when entering disk history or explicitly scrolling, not per frame.
    pub fn history_top_from_end(
        &self,
        id: &str,
        lines_from_end: u64,
        height: usize,
    ) -> Result<Option<i64>> {
        let offset = lines_from_end
            .saturating_add(height.saturating_sub(1) as u64)
            .min(i64::MAX as u64) as i64;
        let top: Option<i64> = self.conn.query_row(
            "SELECT line_no FROM history_lines WHERE session_id=?1 AND TRIM(text)<>'' ORDER BY line_no DESC LIMIT 1 OFFSET ?2",
            params![id,offset], |row| row.get(0)
        ).optional()?;
        if top.is_some() {
            Ok(top)
        } else {
            self.history_first_line(id)
        }
    }

    /// None means an intentional downward scroll reached the live viewport.
    pub fn history_scroll_top(
        &self,
        id: &str,
        first_line: i64,
        delta: i32,
        height: usize,
    ) -> Result<Option<i64>> {
        if delta == 0 {
            return Ok(Some(first_line));
        }
        let steps = delta.unsigned_abs() as i64;
        if delta > 0 {
            let top: Option<i64> = self.conn.query_row(
                "SELECT line_no FROM history_lines WHERE session_id=?1 AND line_no<?2 AND TRIM(text)<>'' ORDER BY line_no DESC LIMIT 1 OFFSET ?3",
                params![id,first_line,steps-1], |row| row.get(0)
            ).optional()?;
            Ok(Some(
                top.or(self
                    .history_first_line(id)?
                    .filter(|line| *line <= first_line))
                    .unwrap_or(first_line),
            ))
        } else {
            let live_top = self.history_top_from_end(id, 0, height)?;
            let top: Option<i64> = self.conn.query_row(
                "SELECT line_no FROM history_lines WHERE session_id=?1 AND line_no>?2 AND TRIM(text)<>'' ORDER BY line_no ASC LIMIT 1 OFFSET ?3",
                params![id,first_line,steps-1], |row| row.get(0)
            ).optional()?;
            Ok(top.filter(|top| live_top.is_some_and(|live_top| *top < live_top)))
        }
    }

    // Kept for the legacy egui executable and raw-log regression fixtures.
    #[allow(dead_code)]
    pub fn append_and_sync(file: &mut File, data: &[u8]) -> Result<()> {
        file.write_all(data)?;
        file.sync_data()?;
        Ok(())
    }
}

#[cfg(test)]
mod history_navigation_tests {
    use super::*;

    fn legacy_store() -> (tempfile::TempDir, Store, i64) {
        let temp = tempfile::tempdir().unwrap();
        let mut store = Store::for_tests(temp.path().to_path_buf()).unwrap();
        store
            .append_command_marks("A", &[(1000.5, 1, 0, "/tmp".into(), "echo result".into())])
            .unwrap();
        store
            .append_history_lines("A", &["".into(), "".into()], &[(1000.5, 1)])
            .unwrap();
        let mark_id = store.recent_command_marks("A", 1).unwrap()[0].id;
        (temp, store, mark_id)
    }

    fn raw_log(store: &Store, session: &str, bytes: &[u8]) {
        Store::append_and_sync(&mut store.log_file(session).unwrap(), bytes).unwrap();
    }

    #[test]
    fn legacy_repair_preserves_command_ids_other_sessions_and_partial_tail() {
        let (_temp, mut store, mark_id) = legacy_store();
        store
            .append_history_lines("B", &["untouched".into()], &[(2000.0, 0)])
            .unwrap();
        raw_log(
            &store,
            "A",
            b"$ echo result\r\n\x1b]133;C;1000.5\x07result\r\npartial\r",
        );
        let mut indexer = store.ensure_history_index("A").unwrap().unwrap();
        assert_eq!(store.command_start_line("A", mark_id).unwrap(), Some(0));
        assert_eq!(
            store.history_page_from("A", 0, 10).unwrap(),
            ["$ echo result", "result"]
        );
        assert_eq!(store.history_page_from("B", 0, 10).unwrap(), ["untouched"]);
        assert_eq!(store.recent_command_marks("A", 1).unwrap()[0].id, mark_id);
        assert!(store.recent_command_marks("A", 1).unwrap()[0].has_anchor);
        let continuation = b"\n\x1b]133;C;1001.5\x07next\r\n";
        raw_log(&store, "A", continuation);
        let lines = indexer.ingest(continuation);
        store
            .append_history_lines("A", &lines, &indexer.take_anchors())
            .unwrap();
        assert_eq!(
            store.history_page_from("A", 0, 10).unwrap(),
            ["$ echo result", "result", "partial", "next"]
        );
        let next: i64 = store
            .conn
            .query_row(
                "SELECT next_line FROM history_counters WHERE session_id='A'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(next, 4);
        assert!(
            store.ensure_history_index("A").unwrap().is_none(),
            "repair is versioned, not repeated"
        );
    }

    #[test]
    fn missing_empty_or_nonfile_logs_never_erase_existing_index() {
        let (_temp, mut store, mark_id) = legacy_store();
        assert!(store.ensure_history_index("A").is_err());
        fs::create_dir(store.log_path("A")).unwrap();
        assert!(store.ensure_history_index("A").is_err());
        fs::remove_dir(store.log_path("A")).unwrap();
        File::create(store.log_path("A")).unwrap();
        assert!(store.ensure_history_index("A").is_err());
        let count: i64 = store
            .conn
            .query_row(
                "SELECT COUNT(*) FROM history_lines WHERE session_id='A'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let next: i64 = store
            .conn
            .query_row(
                "SELECT next_line FROM history_counters WHERE session_id='A'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!((count, next), (2, 2));
        assert_eq!(store.recent_command_marks("A", 1).unwrap()[0].id, mark_id);
        assert!(store.recent_command_marks("A", 1).unwrap()[0].has_anchor);
        let versions: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM history_index_versions", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(versions, 0);
    }

    #[test]
    fn fresh_session_waits_for_output_before_versioning_the_index() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = Store::for_tests(temp.path().to_path_buf()).unwrap();
        assert!(store.ensure_history_index("new").unwrap().is_none());
        File::create(store.log_path("new")).unwrap();
        assert!(store.ensure_history_index("new").unwrap().is_none());
        let versions: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM history_index_versions", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(versions, 0);
        raw_log(&store, "new", b"first output\r\n");
        assert!(store.ensure_history_index("new").unwrap().is_some());
        assert_eq!(
            store.history_page_from("new", 0, 10).unwrap(),
            ["first output"]
        );
    }

    #[test]
    fn missing_or_empty_log_preserves_anchor_and_counter_only_indexes() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = Store::for_tests(temp.path().to_path_buf()).unwrap();
        store
            .append_history_lines("anchor", &[], &[(1000.5, 0)])
            .unwrap();
        store
            .conn
            .execute(
                "INSERT INTO history_counters(session_id,next_line) VALUES('counter',0)",
                [],
            )
            .unwrap();
        for session in ["anchor", "counter"] {
            assert!(store.ensure_history_index(session).is_err());
            File::create(store.log_path(session)).unwrap();
            assert!(store.ensure_history_index(session).is_err());
        }
        let anchors: i64 = store
            .conn
            .query_row(
                "SELECT COUNT(*) FROM command_anchors WHERE session_id='anchor'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let counters: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM history_counters", [], |row| {
                row.get(0)
            })
            .unwrap();
        let versions: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM history_index_versions", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!((anchors, counters, versions), (1, 2, 0));
    }

    #[test]
    fn read_failure_after_first_rebuilt_chunk_rolls_back_all_derived_rows() {
        struct FailingRead {
            first: Option<Vec<u8>>,
        }
        impl Read for FailingRead {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                if let Some(bytes) = self.first.take() {
                    buffer[..bytes.len()].copy_from_slice(&bytes);
                    Ok(bytes.len())
                } else {
                    Err(std::io::Error::other("injected disk error"))
                }
            }
        }
        let (_temp, mut store, mark_id) = legacy_store();
        let chunk = b"replacement\r\n\x1b]133;C;2000\x07".to_vec();
        let length = chunk.len() as u64 + 1;
        let mut reader = FailingRead { first: Some(chunk) };
        assert!(store
            .rebuild_history_index("A", &mut reader, length)
            .is_err());
        let rows: Vec<String> = store
            .conn
            .prepare("SELECT text FROM history_lines WHERE session_id='A' ORDER BY line_no")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        assert_eq!(rows, ["", ""]);
        let next: i64 = store
            .conn
            .query_row(
                "SELECT next_line FROM history_counters WHERE session_id='A'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let anchor: i64 = store
            .conn
            .query_row(
                "SELECT line_no FROM command_anchors WHERE session_id='A' AND started_at=1000.5",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!((next, anchor), (2, 1));
        assert_eq!(store.recent_command_marks("A", 1).unwrap()[0].id, mark_id);
        assert!(store
            .conn
            .query_row(
                "SELECT version FROM history_index_versions WHERE session_id='A'",
                [],
                |row| row.get::<_, i64>(0)
            )
            .optional()
            .unwrap()
            .is_none());
    }

    #[test]
    fn repair_streams_more_than_one_chunk_and_keeps_absolute_page_position() {
        let (_temp, mut store, mark_id) = legacy_store();
        let mut raw = String::from("$ echo result\r\n\x1b]133;C;1000.5\x07");
        for line in 0..10_000 {
            raw.push_str(&format!("output {line}\r\n"));
        }
        raw_log(&store, "A", raw.as_bytes());
        let mut indexer = store.ensure_history_index("A").unwrap().unwrap();
        assert_eq!(store.history_visible_count("A").unwrap(), 10_001);
        let top = store.command_start_line("A", mark_id).unwrap().unwrap();
        let before = store.history_page_from("A", top, 3).unwrap();
        assert_eq!(before, ["$ echo result", "output 0", "output 1"]);
        let added = indexer.ingest(b"new output\r\n");
        store
            .append_history_lines("A", &added, &indexer.take_anchors())
            .unwrap();
        assert_eq!(store.history_page_from("A", top, 3).unwrap(), before);
        assert_eq!(store.history_page_from("A", top, 20).unwrap()[0], before[0]);
        assert_eq!(store.history_scroll_top("A", 5, 2, 20).unwrap(), Some(3));
        assert_eq!(
            store.history_scroll_top("A", 5, i32::MAX, 20).unwrap(),
            Some(0)
        );
        assert_eq!(store.history_scroll_top("A", 5, -2, 20).unwrap(), Some(7));
        assert_eq!(
            store.history_scroll_top("A", 5, i32::MIN, 20).unwrap(),
            None
        );
    }
}
