// SPDX-License-Identifier: MPL-2.0
//! Non-secret backup settings shared by the GUI and recovery CLI.
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BackupConfig {
    pub server: String,
    pub user: String,
    pub remote_path: String,
    pub password_file: String,
}

impl BackupConfig {
    pub fn path() -> Result<PathBuf> {
        Ok(dirs::data_local_dir().context("Missing application data directory")?
            .join("ember-terminal").join("backup.toml"))
    }
    pub fn load() -> Result<Self> {
        let path = Self::path()?;
        if !path.exists() { return Ok(Self::default()); }
        Ok(toml::from_str(&fs::read_to_string(path)?)?)
    }
    // Used by the legacy GUI; the recovery CLI only loads this configuration.
    #[allow(dead_code)]
    pub fn save(&self) -> Result<()> {
        self.repository()?;
        let path = Self::path()?;
        fs::create_dir_all(path.parent().context("No settings folder")?)?;
        let temp = path.with_extension("toml.tmp");
        fs::write(&temp, toml::to_string_pretty(self)?)?;
        fs::rename(temp, path)?;
        Ok(())
    }
    pub fn repository(&self) -> Result<String> {
        let host = self.server.trim();
        let user = self.user.trim();
        let remote = self.remote_path.trim();
        if host.is_empty() || user.is_empty() || !remote.starts_with('/') {
            bail!("Indica servidor, usuario y ruta remota absoluta (/backups/nia)");
        }
        // Never interpolate shell input; these fields are passed as process arguments.
        // Restrict unsafe metacharacters in the restic SFTP address.
        if !host.chars().all(|c| c.is_ascii_alphanumeric() || ".-_".contains(c))
            || !user.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
            || remote.chars().any(|c| c.is_control() || c.is_whitespace() || "\"'`$\\".contains(c))
        { bail!("El servidor, usuario o ruta contiene caracteres no admitidos"); }
        Ok(format!("sftp:{user}@{host}:{remote}"))
    }
    pub fn password_path(&self) -> Result<PathBuf> {
        let p = PathBuf::from(self.password_file.trim());
        if !p.is_absolute() || !p.is_file() {
            bail!("Elige un archivo de contraseña existente con ruta absoluta");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if std::fs::metadata(&p)?.permissions().mode() & 0o077 != 0 {
                bail!("Protege el archivo de contraseña con chmod 600");
            }
        }
        Ok(p)
    }
}
