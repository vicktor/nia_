// SPDX-License-Identifier: MPL-2.0
use serde::Deserialize;
use std::{fs, path::PathBuf};

#[derive(Debug, Clone, Deserialize)]
pub struct Action {
    pub id: String,
    pub name: String,
    pub command: String,
    pub session: Option<String>,
    #[serde(default = "default_confirm")]
    pub confirm: bool,
}
fn default_confirm() -> bool { true }

#[derive(Debug, Default, Deserialize)]
struct ActionsFile { #[serde(default)] actions: Vec<Action> }

pub fn load() -> Vec<Action> {
    let path: Option<PathBuf> = dirs::config_dir().map(|p| p.join("ember-terminal/actions.toml"));
    path.and_then(|p| fs::read_to_string(p).ok())
        .and_then(|s| toml::from_str::<ActionsFile>(&s).ok())
        .map(|x| x.actions)
        .unwrap_or_default()
}

pub fn valid_command(command: &str) -> bool {
    !command.trim().is_empty() && !command.contains('\0') && !command.contains('\r')
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reject_control_characters() {
        assert!(!valid_command(""));
        assert!(!valid_command("echo ok\rnext"));
        assert!(!valid_command("echo \0"));
        assert!(valid_command("git status"));
    }
    #[test]
    fn parse_quick_action() {
        let data = "[[actions]]\nid='git-status'\nname='Git status'\ncommand='git status'\n";
        let config: ActionsFile = toml::from_str(data).unwrap();
        assert_eq!(config.actions.len(),1);
        assert!(config.actions[0].confirm);
    }
}
