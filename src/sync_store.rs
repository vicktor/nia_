// SPDX-License-Identifier: MPL-2.0
//! The sync bridge never shares a connection or a live PTY with the UI.
//! Export reads committed state; import creates a new, closed session atomically.
use crate::storage::Store;
use anyhow::{bail, Context, Result};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

const MAX_TRANSCRIPT: u64 = 2 * 1024 * 1024 * 1024;
const MAX_HISTORY: u64 = 64 * 1024 * 1024;
const MAX_METADATA: u64 = 16 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
pub(crate) struct Metadata {
    title: String,
    cwd: String,
    venv: Option<String>,
    color: String,
    remote_host: Option<String>,
    remote_origin: Option<String>,
    home: String,
    marks: Vec<(f64, i64, i64, String, String)>,
}

fn hex_id(id: &str) -> String {
    id.bytes().map(|b| format!("{b:02x}")).collect()
}
fn shell_dir(store: &Store, id: &str) -> PathBuf {
    store.home.join("shells").join(hex_id(id))
}
fn source(path: PathBuf, limit: u64) -> Result<Value> {
    match fs::symlink_metadata(&path) {
        Ok(meta) => {
            if !meta.is_file() || meta.len() > limit {
                bail!("Sync file is not regular or exceeds the size limit");
            }
            Ok(json!({"path":path, "length":meta.len()}))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Value::Null),
        Err(e) => Err(e.into()),
    }
}

fn export(store: &Store, id: &str) -> Result<Value> {
    // A deferred SQLite read transaction gives metadata one committed revision.
    let tx = store.conn.unchecked_transaction()?;
    let record = store
        .list()?
        .into_iter()
        .find(|r| r.id == id)
        .context("Session not found")?;
    let marks = {
        let mut query = tx.prepare("SELECT started_at,duration_ms,exit_code,cwd,command FROM command_marks WHERE session_id=?1 ORDER BY id LIMIT 100001")?;
        let rows = query.query_map([id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    if marks.len() > 100_000 {
        bail!("Session exceeds the sync command limit (100000)");
    }
    let remote_host = store.remote_host(id)?;
    let metadata = Metadata {
        title: store.session_title(id)?,
        cwd: record.cwd,
        venv: record.venv,
        color: store.session_color(id)?,
        remote_origin: if remote_host.is_some() {
            Some(store.remote_origin(id)?)
        } else {
            None
        },
        remote_host,
        home: dirs::home_dir()
            .context("No home directory")?
            .to_string_lossy()
            .into(),
        marks,
    };
    if serde_json::to_vec(&metadata)?.len() as u64 > MAX_METADATA {
        bail!("Sync metadata exceeds 16 MiB");
    }
    let result = json!({"metadata":metadata,
        "transcript":source(store.log_path(id), MAX_TRANSCRIPT)?,
        "history":source(shell_dir(store,id).join("shell_history"), MAX_HISTORY)?});
    tx.commit()?;
    Ok(result)
}

fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn bounded_file(path: &Path, limit: u64) -> Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file() || meta.len() > limit {
        bail!("Invalid sync file or size limit exceeded");
    }
    Ok(file)
}
fn copy_private(from: &Path, to: &Path, limit: u64) -> Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut input = bounded_file(from, limit)?.take(limit + 1);
    let mut output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(to)?;
    if std::io::copy(&mut input, &mut output)? > limit {
        bail!("Sync file grew beyond limit");
    }
    output.flush()?;
    output.sync_all()?;
    Ok(())
}
fn remap(path: &str, old_home: &str, new_home: &Path) -> PathBuf {
    if !old_home.is_empty() && old_home != "/" {
        if let Ok(relative) = Path::new(path).strip_prefix(old_home) {
            return new_home.join(relative);
        }
    }
    PathBuf::from(path)
}
fn import(store: &Store, revision: &str, stage: &Path, directory: Option<&str>) -> Result<Value> {
    if !uuid(revision) {
        bail!("Invalid revision");
    }
    // SQLite serializes imports from independent app processes. A retry of the
    // same checkpoint returns the original local ID, even after a process crash.
    let tx = store.conn.unchecked_transaction()?;
    tx.execute(
        "UPDATE preferences SET value=value WHERE key='sync-lock'",
        [],
    )?;
    let previous: Option<String> = tx
        .query_row(
            "SELECT session_id FROM sync_imports WHERE revision=?1",
            [revision],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(id) = previous {
        return Ok(json!({"id":id}));
    }
    let metadata: Metadata =
        serde_json::from_reader(bounded_file(&stage.join("metadata.json"), MAX_METADATA)?)?;
    let clean = |s: &str, max: usize| s.len() <= max && !s.contains('\0');
    if !clean(&metadata.title, 512)
        || !clean(&metadata.cwd, 4096)
        || !clean(&metadata.home, 4096)
        || metadata.venv.as_ref().is_some_and(|v| !clean(v, 4096))
        || metadata.marks.len() > 100_000
        || metadata
            .marks
            .iter()
            .any(|m| !m.0.is_finite() || !clean(&m.3, 4096) || !clean(&m.4, 1024 * 1024))
        || metadata.color.len() != 7
        || !metadata.color.starts_with('#')
        || !metadata.color[1..].bytes().all(|b| b.is_ascii_hexdigit())
    {
        bail!("Invalid sync metadata");
    }
    if let Some(host) = &metadata.remote_host {
        if host.is_empty()
            || host.len() > 253
            || host.starts_with('-')
            || host.matches('@').count() > 1
            || !host
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_' | b'@'))
        {
            bail!("Invalid SSH host");
        }
        if metadata
            .remote_origin
            .as_ref()
            .is_none_or(|v| v.is_empty() || !clean(v, 512))
        {
            bail!("Invalid remote session identity");
        }
    }
    let home = dirs::home_dir().context("No home directory")?;
    let cwd = if let Some(host) = &metadata.remote_host {
        format!("SSH: {host}")
    } else {
        let path = directory
            .map(PathBuf::from)
            .unwrap_or_else(|| remap(&metadata.cwd, &metadata.home, &home));
        if !path.is_absolute() || !path.is_dir() {
            bail!("SYNC_DIRECTORY_REQUIRED");
        }
        path.to_string_lossy().into_owned()
    };
    let venv = metadata
        .venv
        .as_ref()
        .map(|v| remap(v, &metadata.home, &home))
        .filter(|p| p.join("bin/activate").is_file() && p.join("bin/python").exists())
        .map(|p| p.to_string_lossy().into_owned());
    // Reserve filesystem destinations in a private staging area, then rename.
    // A crash before DB commit can leave files, but cannot reopen a session or
    // overwrite user data: retry cleans only this revision's reserved paths.
    let mut id = format!("sync-{revision}");
    let mut suffix = 0;
    while store.log_path(&id).exists() || shell_dir(store, &id).exists() {
        suffix += 1;
        if suffix > 1000 {
            bail!("Too many interrupted imports");
        }
        id = format!("sync-{revision}-{suffix}");
    }
    let exists: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM sessions WHERE id=?1)",
        [&id],
        |r| r.get(0),
    )?;
    if exists {
        bail!("Local sync ID already exists");
    }
    let log = store.log_path(&id);
    let shell = shell_dir(store, &id);
    // Do not delete unowned orphan files; use a fresh local suffix after a crash.
    let suffix = tempfile::Builder::new()
        .prefix("import-")
        .tempdir_in(&store.home)?;
    copy_private(
        &stage.join("transcript.bin"),
        &suffix.path().join("transcript.bin"),
        MAX_TRANSCRIPT,
    )?;
    copy_private(
        &stage.join("shell_history"),
        &suffix.path().join("shell_history"),
        MAX_HISTORY,
    )?;
    if log.exists() || shell.exists() {
        bail!("An incomplete local import needs recovery; no files were overwritten");
    }
    fs::create_dir_all(shell.parent().context("No shells directory")?)?;
    fs::create_dir(&shell)?;
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&shell, fs::Permissions::from_mode(0o700))?;
    let result = (|| -> Result<()> {
        fs::rename(suffix.path().join("transcript.bin"), &log)?;
        fs::rename(
            suffix.path().join("shell_history"),
            shell.join("shell_history"),
        )?;
        tx.execute("INSERT INTO sessions(id,cwd,venv,closed,sort_order) VALUES (?1,?2,?3,1,(SELECT COALESCE(MAX(sort_order),0)+1 FROM sessions))", params![id,cwd,venv])?;
        let title_exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM sessions s LEFT JOIN session_titles t ON t.session_id=s.id WHERE s.id=?1 COLLATE NOCASE OR COALESCE(t.title,s.id)=?1 COLLATE NOCASE)",
            [&metadata.title], |r| r.get(0)
        )?;
        let title = if title_exists {
            format!("{} · {}", metadata.title, &revision[..8])
        } else {
            metadata.title.clone()
        };
        tx.execute(
            "INSERT INTO session_titles(session_id,title) VALUES (?1,?2)",
            params![id, title],
        )?;
        tx.execute(
            "INSERT INTO session_colors(session_id,color) VALUES (?1,?2)",
            params![id, metadata.color],
        )?;
        if let Some(host) = &metadata.remote_host {
            tx.execute(
                "INSERT INTO remote_sessions VALUES (?1,?2)",
                params![id, host],
            )?;
            tx.execute(
                "INSERT INTO sync_remote_origins VALUES (?1,?2)",
                params![id, metadata.remote_origin],
            )?;
        }
        for (start, duration, exit, cwd, command) in &metadata.marks {
            tx.execute("INSERT INTO command_marks(session_id,started_at,duration_ms,exit_code,cwd,command) VALUES (?1,?2,?3,?4,?5,?6)", params![id,start,duration,exit,cwd,command])?;
        }
        tx.execute(
            "INSERT INTO sync_imports VALUES (?1,?2)",
            params![revision, id],
        )?;
        tx.commit()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&log);
        let _ = fs::remove_dir_all(&shell);
    }
    result?;
    Ok(json!({"id":id}))
}

pub(crate) fn request(input: &str) -> Result<Value> {
    if input.len() > 16384 {
        bail!("Sync request too large");
    }
    let request: Value = serde_json::from_str(input)?;
    let store = Store::open()?;
    store.conn.busy_timeout(std::time::Duration::from_secs(5))?;
    dispatch(&store, &request)
}
fn dispatch(store: &Store, r: &Value) -> Result<Value> {
    let arg = |key: &str| r[key].as_str().context("Missing sync argument");
    match arg("operation")? {
        "catalog" => Ok(json!(store.list()?.into_iter().map(|r| json!({"id":r.id,"title":store.session_title(&r.id).unwrap_or(r.id),"cwd":r.cwd})).collect::<Vec<_>>())),
        "export" => export(store, arg("id")?),
        "import" => import(store, arg("revision")?, Path::new(arg("stage")?), r["directory"].as_str()),
        _ => bail!("Unknown sync operation"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::SessionRecord;
    const REV: &str = "12345678-1234-1234-1234-123456789012";
    fn fixture() -> (tempfile::TempDir, Store, tempfile::TempDir) {
        let root = tempfile::tempdir().unwrap();
        let mut store = Store::for_tests(root.path().join("db")).unwrap();
        store
            .upsert(&SessionRecord {
                id: "original".into(),
                cwd: root.path().to_string_lossy().into(),
                venv: None,
                closed: false,
            })
            .unwrap();
        store.set_remote_host("original", "me@server").unwrap();
        store
            .log_file("original")
            .unwrap()
            .write_all(b"\x1b[32mhello\x1b[0m\r\n")
            .unwrap();
        store
            .append_command_marks(
                "original",
                &[(1.0, 3, 0, "/tmp".into(), "echo hello".into())],
            )
            .unwrap();
        let stage = tempfile::tempdir().unwrap();
        let export = export(&store, "original").unwrap();
        fs::write(
            stage.path().join("metadata.json"),
            serde_json::to_vec(&export["metadata"]).unwrap(),
        )
        .unwrap();
        fs::copy(
            store.log_path("original"),
            stage.path().join("transcript.bin"),
        )
        .unwrap();
        fs::write(stage.path().join("shell_history"), "echo hello\n").unwrap();
        (root, store, stage)
    }
    #[test]
    fn cross_store_import_is_idempotent_and_preserves_ansi_timeline_remote_identity() {
        let (_root, _source, stage) = fixture();
        let dest = tempfile::tempdir().unwrap();
        let store = Store::for_tests(dest.path().join("db")).unwrap();
        let first = import(&store, REV, stage.path(), None).unwrap();
        assert_eq!(first, import(&store, REV, stage.path(), None).unwrap());
        let id = first["id"].as_str().unwrap();
        assert_eq!(store.list().unwrap().len(), 1);
        assert!(store.list().unwrap()[0].closed);
        assert_eq!(store.remote_origin(id).unwrap(), "original");
        assert_eq!(store.remote_host(id).unwrap().as_deref(), Some("me@server"));
        assert_eq!(
            fs::read(store.log_path(id)).unwrap(),
            b"\x1b[32mhello\x1b[0m\r\n"
        );
        assert_eq!(
            store.recent_command_marks(id, 20).unwrap()[0].command,
            "echo hello"
        );
        assert!(!shell_dir(&store, id).join("agent-resume").exists());
    }
    #[test]
    fn rejects_invalid_revision_and_partial_import_without_overwriting_source() {
        let (_root, store, stage) = fixture();
        assert!(import(&store, "../../evil", stage.path(), None).is_err());
        fs::remove_file(stage.path().join("shell_history")).unwrap();
        assert!(import(&store, REV, stage.path(), None).is_err());
        assert_eq!(store.list().unwrap().len(), 1);
        assert_eq!(store.remote_origin("original").unwrap(), "original");
    }
    #[test]
    fn rejects_symlink_and_shell_injection() {
        let (_root, store, stage) = fixture();
        let path = stage.path().join("metadata.json");
        let mut metadata: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        metadata["remote_host"] = json!("host; touch /tmp/evil");
        fs::write(&path, serde_json::to_vec(&metadata).unwrap()).unwrap();
        assert!(import(&store, REV, stage.path(), None).is_err());
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink("/etc/passwd", &path).unwrap();
        assert!(import(&store, REV, stage.path(), None).is_err());
    }
    #[test]
    fn interrupted_import_retries_without_removing_orphan_or_existing_data() {
        let (_root, store, stage) = fixture();
        let orphan = store.log_path(&format!("sync-{REV}"));
        fs::write(&orphan, b"preserve interrupted data").unwrap();
        let result = import(&store, REV, stage.path(), None).unwrap();
        assert_eq!(result["id"], format!("sync-{REV}-1"));
        assert_eq!(fs::read(orphan).unwrap(), b"preserve interrupted data");
        assert_eq!(store.list().unwrap().len(), 2);
    }
    #[test]
    fn missing_project_requires_explicit_directory_and_imports_no_startup_scripts() {
        let (root, store, stage) = fixture();
        let path = stage.path().join("metadata.json");
        let mut data: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        data["remote_host"] = Value::Null;
        data["remote_origin"] = Value::Null;
        data["cwd"] = json!("/nia-nonexistent-project-directory");
        fs::write(&path, serde_json::to_vec(&data).unwrap()).unwrap();
        fs::write(stage.path().join("agent-resume"), "arbitrary code").unwrap();
        fs::write(stage.path().join(".zshrc"), "arbitrary code").unwrap();
        assert!(import(&store, REV, stage.path(), None)
            .unwrap_err()
            .to_string()
            .contains("SYNC_DIRECTORY_REQUIRED"));
        assert_eq!(store.list().unwrap().len(), 1);
        let result = import(&store, REV, stage.path(), root.path().to_str()).unwrap();
        let id = result["id"].as_str().unwrap();
        assert!(!shell_dir(&store, id).join("agent-resume").exists());
        assert!(!shell_dir(&store, id).join(".zshrc").exists());
        assert_eq!(
            store
                .list()
                .unwrap()
                .iter()
                .find(|r| r.id == id)
                .unwrap()
                .cwd,
            root.path().to_string_lossy()
        );
    }
    #[test]
    fn home_mapping_requires_path_component_boundary() {
        assert_eq!(
            remap("/Users/a/project", "/Users/a", Path::new("/Users/b")),
            Path::new("/Users/b/project")
        );
        assert_eq!(
            remap("/Users/abc/project", "/Users/a", Path::new("/Users/b")),
            Path::new("/Users/abc/project")
        );
    }
}
