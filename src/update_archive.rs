// SPDX-License-Identifier: MPL-2.0
//! Extract an update into a new directory, never over a running app or user data.
use anyhow::{bail, ensure, Context, Result};
use std::{fs, io, path::{Component, Path}};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const MAX_EXPANDED_BYTES: u64 = 2 * 1024 * 1024 * 1024;

pub fn unpack(archive: &Path, destination: &Path) -> Result<()> {
    let mut zip = zip::ZipArchive::new(fs::File::open(archive)?)?;
    ensure!(zip.len() <= 100_000, "Too many update entries");
    let mut total = 0u64;
    // Validate the entire directory before writing any archive content.
    for i in 0..zip.len() {
        let entry = zip.by_index(i)?;
        let name = entry.name()?;
        ensure!(!name.contains('\\'), "Invalid archive path");
        let path = entry.enclosed_name().context("Archive path escapes destination")?;
        ensure!(path.components().all(|c| matches!(c, Component::Normal(_))), "Invalid archive path");
        let root = path.components().next().context("Empty archive path")?;
        ensure!(root.as_os_str() == "nia_.app" || root.as_os_str() == "__MACOSX", "Unexpected archive root");
        let kind = entry.unix_mode().unwrap_or(0) & 0o170000;
        ensure!(kind == 0 || kind == 0o100000 || kind == 0o040000, "Links and special files are not allowed in updates");
        total = total.checked_add(entry.size()).context("Update size overflow")?;
        ensure!(total <= MAX_EXPANDED_BYTES, "Update is too large");
    }
    // create_dir deliberately refuses an existing destination, including links.
    fs::create_dir(destination)?;
    let result = (|| {
        for i in 0..zip.len() {
            let mut entry = zip.by_index(i)?;
            let relative = entry.enclosed_name().context("Invalid archive path")?;
            if relative.starts_with("__MACOSX") { continue; }
            let target = destination.join(relative);
            if entry.is_dir() {
                fs::create_dir_all(&target)?;
                continue;
            }
            fs::create_dir_all(target.parent().context("Missing parent")?)?;
            let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&target)?;
            let expected = entry.size();
            let actual = io::copy(&mut io::Read::take(&mut entry, expected + 1), &mut file)?;
            ensure!(actual == expected, "Invalid expanded size");
            #[cfg(unix)]
            fs::set_permissions(&target, fs::Permissions::from_mode(entry.unix_mode().unwrap_or(0o644) & 0o755))?;
        }
        if !destination.join("nia_.app/Contents/Info.plist").is_file() {
            bail!("Missing application bundle");
        }
        Ok(())
    })();
    if result.is_err() { let _ = fs::remove_dir_all(destination); }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    fn archive(root: &Path, entries: &[(&str, &[u8])], link: bool) -> std::path::PathBuf {
        let path = root.join("update.zip");
        let mut zip = zip::ZipWriter::new(fs::File::create(&path).unwrap());
        for (name, contents) in entries {
            zip.start_file(*name, SimpleFileOptions::default().unix_permissions(0o755)).unwrap();
            zip.write_all(contents).unwrap();
        }
        if link { zip.add_symlink("nia_.app/link", "../../outside", SimpleFileOptions::default()).unwrap(); }
        zip.finish().unwrap();
        path
    }

    #[test]
    fn extracts_bundle_and_preserves_executable_permissions() {
        let root = tempfile::tempdir().unwrap();
        let zip = archive(root.path(), &[("nia_.app/Contents/Info.plist", b"plist"), ("nia_.app/Contents/MacOS/nia", b"executable")], false);
        let dest = root.path().join("extracted");
        unpack(&zip, &dest).unwrap();
        let exe = dest.join("nia_.app/Contents/MacOS/nia");
        assert_eq!(fs::read(&exe).unwrap(), b"executable");
        #[cfg(unix)]
        assert_eq!(fs::metadata(exe).unwrap().permissions().mode() & 0o777, 0o755);
        assert!(unpack(&zip, &dest).is_err());
    }

    #[test]
    fn rejects_path_escape_and_unexpected_roots_without_writing() {
        for name in ["../outside", "/tmp/outside", "nia_.app/../../outside", "Other.app/Contents/Info.plist", "nia_.app\\outside"] {
            let root = tempfile::tempdir().unwrap();
            let zip = archive(root.path(), &[(name, b"bad")], false);
            let dest = root.path().join("extracted");
            assert!(unpack(&zip, &dest).is_err(), "{name}");
            assert!(!dest.exists());
        }
    }

    #[test]
    fn rejects_symlinks_and_incomplete_bundles() {
        let root = tempfile::tempdir().unwrap();
        let dest = root.path().join("extracted");
        let zip = archive(root.path(), &[("nia_.app/Contents/Info.plist", b"plist")], true);
        assert!(unpack(&zip, &dest).is_err());
        assert!(!dest.exists());
        let zip = archive(root.path(), &[("nia_.app/file", b"data")], false);
        assert!(unpack(&zip, &dest).is_err());
        assert!(!dest.exists());
    }
}
