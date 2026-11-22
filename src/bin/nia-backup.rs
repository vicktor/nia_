// SPDX-License-Identifier: MPL-2.0
//! Nia's disaster-recovery CLI. All remote data is encrypted by restic.
//! No plaintext archives are retained after successful or failed operations.
use anyhow::{bail, Context, Result};
#[path = "../backup_config.rs"]
mod backup_config;
use std::{env, fs::{self, File}, io::{self}, path::{Path, PathBuf}, process::{Command, Stdio}};
use tempfile::tempdir;
use walkdir::WalkDir;
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

const ARCHIVE_NAME: &str = "nia-recovery.zip";

fn app_dir() -> Result<PathBuf> {
    // The GUI still uses the old data location until a separate, tested migration.
    Ok(dirs::data_local_dir().context("No application data directory")?.join("ember-terminal"))
}

fn check_configuration() -> Result<()> {
    // Prefer explicit environment variables (for migration and recovery on a new Mac),
    // then fall back to non-secret GUI preferences.
    if env::var_os("RESTIC_REPOSITORY").is_none() {
        let cfg = backup_config::BackupConfig::load()?;
        env::set_var("RESTIC_REPOSITORY", cfg.repository()?);
        if ["RESTIC_PASSWORD_COMMAND", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD"].iter().all(|k| env::var_os(k).is_none()) {
            env::set_var("RESTIC_PASSWORD_FILE", cfg.password_path()?);
        }
    }
    if env::var_os("RESTIC_REPOSITORY").is_none() { bail!("Set RESTIC_REPOSITORY to a dedicated Nia repository (SFTP, S3 or local)"); }
    if ["RESTIC_PASSWORD_COMMAND", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD"].iter().all(|k| env::var_os(k).is_none()) {
        bail!("Configure RESTIC_PASSWORD_COMMAND or RESTIC_PASSWORD_FILE; save the recovery passphrase outside your Macs");
    }
    let status = Command::new("restic").arg("version").stdout(Stdio::null()).status().context("Install restic (brew install restic)")?;
    if !status.success() { bail!("restic is not working"); }
    Ok(())
}

fn restic(args: &[&str]) -> Result<()> {
    let status = Command::new("restic").args(args).status().context("Failed to run restic")?;
    if !status.success() { bail!("restic failed ({status})"); }
    Ok(())
}

fn snapshot_database(src: &Path, dst: &Path) -> Result<()> {
    let conn = rusqlite::Connection::open_with_flags(src, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("Opening {}", src.display()))?;
    // VACUUM INTO safely snapshots a live SQLite database, including committed WAL records.
    conn.execute("VACUUM INTO ?1", [dst.to_string_lossy().as_ref()])?;
    let check = rusqlite::Connection::open_with_flags(dst, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let integrity: String = check.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
    if integrity != "ok" { bail!("SQLite snapshot failed integrity_check: {integrity}"); }
    Ok(())
}

fn copy_regular_tree(src: &Path, dest: &Path) -> Result<()> {
    if !src.exists() { return Ok(()); }
    for item in WalkDir::new(src).follow_links(false) {
        let item = item?;
        let relative = item.path().strip_prefix(src)?;
        let dest_path = dest.join(relative);
        if item.file_type().is_dir() { fs::create_dir_all(&dest_path)?; }
        else if item.file_type().is_file() {
            if let Some(parent) = dest_path.parent() { fs::create_dir_all(parent)?; }
            fs::copy(item.path(), &dest_path)?;
        }
        // Symlinks are deliberately skipped. Never walk out of the data directory.
    }
    Ok(())
}

fn build_archive(dest: &Path) -> Result<()> {
    let data = app_dir()?;
    let db = data.join("sessions.sqlite3");
    if !db.is_file() { bail!("No Nia database at {}", db.display()); }
    let staging = tempdir()?;
    let root = staging.path().join("state");
    fs::create_dir_all(&root)?;
    snapshot_database(&db, &root.join("sessions.sqlite3"))?;
    for name in ["logs", "shells"] { copy_regular_tree(&data.join(name), &root.join(name))?; }
    let actions = data.join("actions.toml");
    if actions.is_file() { fs::copy(actions, root.join("actions.toml"))?; }
    fs::write(root.join("format-version"), "nia-recovery-v1\n")?;
    let file = File::create(dest)?;
    let mut zip = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    for entry in WalkDir::new(&root) {
        let entry = entry?;
        if !entry.file_type().is_file() { continue; }
        let relative = entry.path().strip_prefix(staging.path())?;
        let zip_name = relative.to_string_lossy().replace('\\', "/");
        zip.start_file(zip_name, options)?;
        io::copy(&mut File::open(entry.path())?, &mut zip)?;
    }
    zip.finish()?;
    Ok(())
}

fn backup() -> Result<()> {
    check_configuration()?;
    let tmp = tempdir()?;
    let archive = tmp.path().join(ARCHIVE_NAME);
    build_archive(&archive)?;
    // The archive is prepared completely first, so interrupted assembly cannot
    // accidentally create an apparently successful remote snapshot.
    let input = File::open(&archive)?;
    let status = Command::new("restic")
        .args(["backup", "--stdin", "--stdin-filename", ARCHIVE_NAME, "--tag", "nia-backup"])
        .stdin(Stdio::from(input)).status()?;
    if !status.success() { bail!("Remote backup failed ({status})"); }
    println!("Encrypted Nia recovery snapshot uploaded successfully.");
    Ok(())
}

fn unpack_archive(path: &Path, destination: &Path) -> Result<()> {
    let mut archive = ZipArchive::new(File::open(path)?)?;
    let mut names = Vec::new();
    for i in 0..archive.len() {
        let entry = archive.by_index(i)?;
        let safe = entry.enclosed_name().context("Invalid ZIP path")?.to_owned();
        if !safe.starts_with("state") || entry.is_dir() { bail!("Unexpected file in backup: {}", safe.display()); }
        // Never restore arbitrary files, even if a backup is tampered with.
        if safe == Path::new("state/format-version") || safe == Path::new("state/sessions.sqlite3")
            || safe == Path::new("state/actions.toml") || safe.starts_with("state/logs") || safe.starts_with("state/shells") {
            names.push(safe);
        } else { bail!("Unrecognized file in backup: {}", safe.display()); }
    }
    if !names.iter().any(|p| p == Path::new("state/sessions.sqlite3"))
        || !names.iter().any(|p| p == Path::new("state/format-version")) { bail!("Missing recovery manifest or database"); }
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let relative = entry.enclosed_name().context("Unsafe path")?.to_owned();
        let target = destination.join(relative);
        if let Some(parent) = target.parent() { fs::create_dir_all(parent)?; }
        let mut out = File::create(&target)?;
        io::copy(&mut entry, &mut out)?;
    }
    if fs::read_to_string(destination.join("state/format-version"))?.trim() != "nia-recovery-v1" {
        bail!("Unsupported backup format");
    }
    let conn = rusqlite::Connection::open(destination.join("state/sessions.sqlite3"))?;
    let integrity: String = conn.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
    if integrity != "ok" { bail!("Restored SQLite failed integrity_check"); }
    println!("Recovery files verified at {}", destination.join("state").display());
    println!("Close Nia before importing these files. See RECOVERY.md.");
    Ok(())
}

fn restore(dest: &Path) -> Result<()> {
    check_configuration()?;
    if dest.exists() && fs::read_dir(dest)?.next().is_some() {
        bail!("Restore destination must be an empty directory: {}", dest.display());
    }
    let staging = tempdir()?;
    // Dedicated Nia repo is required; no mixing backups with other applications.
    restic(&["restore", "latest", "--target", staging.path().to_str().context("Invalid staging path")?])?;
    let archive = staging.path().join(ARCHIVE_NAME);
    if !archive.is_file() { bail!("Snapshot did not contain {ARCHIVE_NAME}; use a dedicated Nia repository"); }
    fs::create_dir_all(dest)?;
    unpack_archive(&archive, dest)
}

pub fn execute(command: &str, destination: Option<&Path>) -> Result<()> {
    match command {
        "init" => { check_configuration()?; restic(&["init"]) },
        "backup" => backup(),
        "snapshots" => { check_configuration()?; restic(&["snapshots", "--tag", "nia-backup"]) },
        "check" => { check_configuration()?; restic(&["check"]) },
        "restore" => {
            let path = destination.context("Usage: nia-backup restore /path/to/EMPTY-directory")?;
            restore(path)
        },
        _ => {
            eprintln!("Nia disaster recovery\nCommands: init | backup | snapshots | check | restore <empty-directory>\nRequires restic and RESTIC_REPOSITORY + RESTIC_PASSWORD_COMMAND/FILE.\nNever put secrets directly on the command line.");
            Ok(())
        }
    }
}

fn main() -> Result<()> {
    let mut args = env::args().skip(1);
    let command = args.next().unwrap_or_default();
    let destination = args.next().map(PathBuf::from);
    execute(&command, destination.as_deref())
}
