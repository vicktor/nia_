// SPDX-License-Identifier: MPL-2.0
//! Commands eligible for automatic recovery of an interrupted local session.

/// Recognize a single literal invocation, never arbitrary shell history.
/// Retain its quoting (including ~/ paths) so replay has the same arguments.
pub(crate) fn validated_resume(source: &str) -> Option<String> {
    if source.len() > 8192 || !literal_command(source) {
        return None;
    }
    let words = shell_words::split(source).ok()?;
    let parts: Vec<&str> = words.iter().map(String::as_str).collect();
    let agent = match parts.as_slice() {
        ["claude", "--resume", id] => Some(("claude --resume", *id)),
        ["codex", "resume", id] => Some(("codex resume", *id)),
        ["agy", "--conversation" | "--resume" | "-r", id] => Some(("agy --conversation", *id)),
        ["agy", option] => option
            .strip_prefix("--conversation=")
            .or_else(|| option.strip_prefix("--resume="))
            .map(|id| ("agy --conversation", id)),
        ["gemini", "--resume" | "-r", id] => Some(("gemini --resume", *id)),
        ["gemini", option] => option
            .strip_prefix("--resume=")
            .map(|id| ("gemini --resume", id)),
        _ => None,
    };
    if let Some((provider, id)) = agent {
        if (8..=128).contains(&id.len())
            && id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            && (provider != "gemini --resume" || !id.bytes().all(|b| b.is_ascii_digit()))
        {
            return Some(if provider == "agy --conversation" {
                format!("{provider}={id}")
            } else {
                format!("{provider} {id}")
            });
        }
        return None;
    }
    if matches!(parts.first(), Some(&"ssh" | &"/usr/bin/ssh")) && ssh_connection(&parts[1..]) {
        return Some(source.trim().to_owned());
    }
    None
}

/// shell-words handles quoting; this scan rejects shell evaluation/operators
/// that its argv parser intentionally treats as ordinary characters.
fn literal_command(source: &str) -> bool {
    if source.chars().any(|c| c.is_control() && c != '\t') {
        return false;
    }
    let mut quote = None;
    let mut chars = source.chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some('\''), '\'') => quote = None,
            (Some('\''), _) => {}
            (_, '\\') => {
                if chars.next().is_none() {
                    return false;
                }
            }
            (Some('"'), '"') => quote = None,
            (_, '$' | '`' | '!') => return false,
            (None, '\'' | '"') => quote = Some(c),
            (
                None,
                ';' | '|' | '&' | '<' | '>' | '(' | ')' | '{' | '}' | '*' | '?' | '[' | ']' | '#',
            ) => return false,
            _ => {}
        }
    }
    quote.is_none()
}

fn ssh_connection(args: &[&str]) -> bool {
    let mut destination = None;
    let mut options = true;
    let mut index = 0;
    while let Some(&arg) = args.get(index) {
        index += 1;
        if options && arg == "--" {
            options = false;
        } else if options && arg.starts_with('-') {
            if arg.len() == 1 {
                return false;
            }
            let mut flags = arg[1..].char_indices();
            while let Some((offset, flag)) = flags.next() {
                if "46AaCKkNqTtvXxYy".contains(flag) {
                    continue;
                }
                if !"BbcDEeFiJLlmopPRS".contains(flag) {
                    return false;
                }
                let tail = &arg[1 + offset + flag.len_utf8()..];
                let value = if tail.is_empty() {
                    let Some(&value) = args.get(index) else {
                        return false;
                    };
                    index += 1;
                    value
                } else {
                    tail
                };
                if value.is_empty() || value.starts_with('-') {
                    return false;
                }
                if flag == 'p' && !value.parse::<u16>().is_ok_and(|port| port > 0) {
                    return false;
                }
                if flag == 'o' && !ssh_config_option(value) {
                    return false;
                }
                break; // The rest of this word belongs to the option value.
            }
        } else {
            // A second positional argument would be a remote command.
            if destination.is_some() || !ssh_destination(arg) {
                return false;
            }
            destination = Some(arg);
        }
    }
    destination.is_some()
}

fn ssh_destination(value: &str) -> bool {
    let host = value.strip_prefix("ssh://").unwrap_or(value);
    !host.is_empty()
        && !host.starts_with('-')
        && host.len() <= 1024
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-@:%[]".contains(&b))
}

fn ssh_config_option(value: &str) -> bool {
    let Some((key, argument)) = value.split_once(['=', ' ', '\t']) else {
        return false;
    };
    !argument.trim().is_empty()
        && matches!(
            key.to_ascii_lowercase().as_str(),
            "hostname"
                | "user"
                | "port"
                | "identityfile"
                | "identitiesonly"
                | "proxyjump"
                | "forwardagent"
                | "forwardx11"
                | "forwardx11trusted"
                | "serveraliveinterval"
                | "serveralivecountmax"
                | "connecttimeout"
                | "connectionattempts"
                | "stricthostkeychecking"
                | "userknownhostsfile"
                | "globalknownhostsfile"
                | "preferredauthentications"
                | "pubkeyauthentication"
                | "passwordauthentication"
                | "kbdinteractiveauthentication"
                | "batchmode"
                | "addressfamily"
                | "compression"
                | "requesttty"
                | "controlmaster"
                | "controlpath"
                | "controlpersist"
                | "addkeystoagent"
                | "usekeychain"
                | "hostkeyalgorithms"
                | "pubkeyacceptedalgorithms"
                | "kexalgorithms"
                | "ciphers"
                | "macs"
                | "loglevel"
                | "exitonforwardfailure"
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agents_resume_explicit_stable_ids_including_gemini_short_and_equals_forms() {
        let id = "123e4567-e89b-12d3-a456-426614174000";
        for (invocation, expected) in [
            ("claude --resume ", "claude --resume"),
            ("codex resume ", "codex resume"),
            ("gemini --resume ", "gemini --resume"),
            ("gemini -r ", "gemini --resume"),
            ("gemini --resume=", "gemini --resume"),
        ] {
            assert_eq!(
                validated_resume(&format!("{invocation}{id}")),
                Some(format!("{expected} {id}"))
            );
        }
        for source in [
            "gemini",
            "gemini -r",
            "gemini --resume latest",
            "gemini -r 1",
            "gemini -r 12345678",
            "codex resume --last",
            "claude --continue",
            "sudo claude --resume 12345678",
            "gemini -r 12345678; echo bad",
        ] {
            assert!(validated_resume(source).is_none(), "{source}");
        }
    }

    #[test]
    fn antigravity_resumes_explicit_conversation_ids() {
        let id = "123e4567-e89b-12d3-a456-426614174000";
        for source in [
            format!("agy --conversation={id}"),
            format!("agy --conversation {id}"),
            format!("agy --conversation='{id}'"),
            format!("  agy --conversation=\"{id}\"  "),
            format!("agy --resume {id}"),
            format!("agy --resume={id}"),
            format!("agy -r {id}"),
        ] {
            assert_eq!(
                validated_resume(&source),
                Some(format!("agy --conversation={id}")),
                "{source}"
            );
        }
        for source in [
            "agy".to_owned(),
            "agy --conversation".to_owned(),
            "agy --conversation=".to_owned(),
            "agy --continue".to_owned(),
            "agy -c".to_owned(),
            "agy --conversation=short".to_owned(),
            format!("agy --conversation={}", "a".repeat(129)),
            "agy --conversation='id with spaces'".to_owned(),
            "agy --conversation=$CONVERSATION_ID".to_owned(),
            "agy --conversation=$(echo 12345678)".to_owned(),
            "agy --conversation=`echo 12345678`".to_owned(),
            format!("agy --conversation={id}; echo bad"),
            format!("agy --conversation={id} --print prompt"),
            format!("agy --conversation={id} --dangerously-skip-permissions"),
            format!("agy --conversation={id} --conversation=abcdefgh"),
            format!("agy --conversation={id}\nwhoami"),
        ] {
            assert!(validated_resume(&source).is_none(), "{source}");
        }
    }

    #[test]
    fn ssh_preserves_connection_options_quotes_and_paths() {
        for source in [
            "ssh production",
            "ssh user@server.example",
            "/usr/bin/ssh -p 2222 user@host",
            "ssh -Avtt -p2222 -l victor host",
            "ssh host -p 2222",
            "ssh -i ~/.ssh/id_ed25519 -F ~/.ssh/work-config host",
            "ssh -i '/tmp/my key' -J gateway,jump2:2222 host",
            "ssh -o ServerAliveInterval=30 -o 'IdentityFile=/tmp/my key' host",
            "ssh -oUseKeychain=yes -- host",
            "ssh 'user@[2001:db8::1]'",
            "ssh ssh://user@host:2222",
            "ssh -N -L 8080:localhost:80 host",
            "ssh -i '/tmp/a;literal-key' host",
            "ssh -i '/tmp/a'\\''b' host",
        ] {
            assert_eq!(
                validated_resume(source).as_deref(),
                Some(source),
                "{source}"
            );
        }
    }

    #[test]
    fn ssh_does_not_replay_remote_commands_or_shell_evaluation() {
        for source in [
            "ssh host reboot",
            "ssh host 'rm -rf /tmp/example'",
            "ssh host; echo bad",
            "ssh host && echo bad",
            "ssh host | cat",
            "ssh host &",
            "ssh host > log",
            "ssh $(hostname)",
            "ssh `hostname`",
            "ssh $SERVER",
            "ssh \"$SERVER\"",
            "ssh -i \"/tmp/!!\" host",
            "ssh host\nwhoami",
            "ssh host\rwhoami",
            "ssh ho\0st",
            "ssh -i *.pem host",
            "ssh [ab]",
            "ssh #comment",
            "ssh 'unterminated",
            "ssh host\\",
            "ssh -oRemoteCommand=reboot host",
            "ssh -o 'LocalCommand=echo bad' host",
            "ssh -oProxyCommand=command host",
            "ssh -f host",
            "ssh -G host",
            "ssh -O exit host",
            "ssh -Q cipher",
            "ssh -p",
            "ssh -p host",
            "ssh -p0 host",
            "ssh -p65536 host",
            "ssh -oBatchMode=yes",
            "ssh -- -host",
            "ssh -- host -p 22",
            "sudo ssh host",
            "echo ssh host",
        ] {
            assert!(validated_resume(source).is_none(), "{source}");
        }
        assert!(validated_resume(&format!("ssh {}", "a".repeat(9000))).is_none());
    }
}
