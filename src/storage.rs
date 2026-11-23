// SPDX-License-Identifier: MPL-2.0
use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::{fs::{self, File, OpenOptions}, io::{Read, Write}, path::PathBuf};

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
        let base = dirs::data_local_dir().context("no local data directory")?.join("ember-terminal");
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
    fn log_path(&self, id: &str) -> PathBuf {
        let mut key = String::with_capacity(id.len() * 2);
        for b in id.bytes() { key.push_str(&format!("{b:02x}")); }
        self.home.join("logs").join(format!("{key}.bin"))
    }

    pub fn log_file(&self, id: &str) -> Result<File> {
        Ok(OpenOptions::new().create(true).append(true).open(self.log_path(id))?)
    }

    /// Reconstruct the VT parser from the preserved byte log with bounded RAM.
    /// Unlike replay(limit), this does not discard histories above 32 MiB.
    pub fn replay_stream(&self, id: &str, mut consume: impl FnMut(&[u8])) -> Result<()> {
        let path = self.log_path(id);
        if !path.exists() { return Ok(()); }
        let mut file = File::open(path)?;
        let mut chunk = [0u8; 64 * 1024];
        loop {
            let count = file.read(&mut chunk)?;
            if count == 0 { break; }
            consume(&chunk[..count]);
        }
        Ok(())
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

    /// Count readable lines AFTER an explicit marker; its output can be
    /// positioned at the top of a viewport by paging back from the end.
    pub fn readable_lines_since_command(&self, session: &str, mark_id: i64) -> Result<Option<u64>> {
        let line: Option<i64> = self.conn.query_row(
            "SELECT a.line_no FROM command_marks m
             JOIN command_anchors a ON a.session_id=m.session_id AND a.started_at=m.started_at
             WHERE m.session_id=?1 AND m.id=?2",
            params![session,mark_id], |r| r.get(0)
        ).optional()?;
        let Some(line) = line else { return Ok(None) };
        let count: i64 = self.conn.query_row(
            // The OSC marker is emitted at preexec, *after* the shell has
            // echoed the command line. Include its preceding indexed line so
            // navigation lands on the original command rather than only output.
            "SELECT COUNT(*) FROM history_lines
             WHERE session_id=?1 AND line_no>=?2 AND TRIM(text)<>''",
            params![session,line.saturating_sub(1)], |r| r.get(0)
        )?;
        Ok(Some(count.max(0) as u64))
    }

    /// Count non-empty transcript lines, excluding terminal progress/blank-only rows.
    /// This is an index of readable output, not a pixel-perfect VT replay.
    pub fn history_visible_count(&self, id: &str) -> Result<u64> {
        let total: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM history_lines WHERE session_id=?1 AND TRIM(text) <> ''",
            [id], |row| row.get(0))?;
        Ok(total.max(0) as u64)
    }

    /// Return at most one viewport of non-blank rows, oldest to newest.
    /// We intentionally clamp OFFSET before reading so scrolling past the oldest
    /// available text cannot turn the view into a screen full of empty cells.
    pub fn history_visible_page(&self, id: &str, lines_from_end: u64, count: usize) -> Result<Vec<String>> {
        let count = count.clamp(1, 300);
        let offset = lines_from_end;
        let mut stmt = self.conn.prepare(
            "SELECT text FROM history_lines WHERE session_id=?1 AND TRIM(text) <> '' \
             ORDER BY line_no DESC LIMIT ?2 OFFSET ?3")?;
        let mut items = stmt.query_map(params![id, count as i64, offset as i64],
            |row| row.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
        items.reverse();
        Ok(items)
    }

    pub fn append_and_sync(file: &mut File, data: &[u8]) -> Result<()> {
        file.write_all(data)?;
        file.sync_data()?;
        Ok(())
    }
}
