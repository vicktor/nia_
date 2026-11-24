// SPDX-License-Identifier: MPL-2.0
//! Claude Code statusLine adapter. Only numeric usage leaves the input stream;
//! the original command, if any, receives its original stdin and stdout.
use serde_json::{json, Value};
use std::{io::{self, Read, Write}, path::Path, process::{Command, Stdio}, time::{SystemTime, UNIX_EPOCH}};

fn snapshot(input: &Value, now: u64) -> Value {
    fn window(value: &Value) -> Value {
        match (value["used_percentage"].as_f64(), value["resets_at"].as_f64()) {
            (Some(used), Some(reset)) if (0.0..=100.0).contains(&used) && reset > 0.0 =>
                json!({"used_percentage": used, "resets_at": reset}),
            _ => Value::Null,
        }
    }
    json!({
        "updated_at": now,
        "rate_limits": {
            "five_hour": window(&input["rate_limits"]["five_hour"]),
            "seven_day": window(&input["rate_limits"]["seven_day"]),
        },
        "input_tokens": input["context_window"]["total_input_tokens"].as_u64(),
        "output_tokens": input["context_window"]["total_output_tokens"].as_u64(),
    })
}

fn save(output: &Path, value: &Value) -> anyhow::Result<()> {
    let directory = output.parent().ok_or_else(|| anyhow::anyhow!("Missing parent"))?;
    std::fs::create_dir_all(directory)?;
    let mut temporary = tempfile::NamedTempFile::new_in(directory)?;
    serde_json::to_writer(&mut temporary, value)?;
    temporary.flush()?;
    temporary.persist(output)?;
    Ok(())
}

fn main() {
    let mut args = std::env::args().skip(1);
    let mut output = None;
    let mut previous = None;
    while let Some(flag) = args.next() {
        match flag.as_str() {
            "--output" => output = args.next(),
            "--previous-command" => previous = args.next(),
            _ => return,
        }
    }
    let mut data = Vec::new();
    if io::stdin().take(2 * 1024 * 1024).read_to_end(&mut data).is_err() { return; }
    if let (Some(output), Ok(input)) = (output, serde_json::from_slice::<Value>(&data)) {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
        let _ = save(Path::new(&output), &snapshot(&input, now));
    }
    if let Some(previous) = previous {
        if let Ok(mut child) = Command::new("/bin/sh").arg("-c").arg(previous)
            .stdin(Stdio::piped()).stdout(Stdio::inherit()).stderr(Stdio::inherit()).spawn() {
            if let Some(mut stdin) = child.stdin.take() { let _ = stdin.write_all(&data); }
            if let Ok(status) = child.wait() { std::process::exit(status.code().unwrap_or(1)); }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn saves_only_valid_numeric_usage_not_conversation_or_identity() {
        let input = json!({"session_id":"private", "transcript_path":"secret/path", "prompt":"secret text",
            "rate_limits":{"seven_day":{"used_percentage":42.5,"resets_at":12345,"extra":"secret"},"five_hour":{"used_percentage":999,"resets_at":1}},
            "context_window":{"total_input_tokens":10,"total_output_tokens":20}});
        let result = snapshot(&input, 100);
        assert_eq!(result["rate_limits"]["seven_day"]["used_percentage"], 42.5);
        assert!(result["rate_limits"]["five_hour"].is_null());
        assert_eq!(result["input_tokens"], 10);
        let serialized = result.to_string();
        assert!(!serialized.contains("secret") && !serialized.contains("private"));
    }
    #[test]
    fn missing_limits_are_unknown_not_zero() {
        let result = snapshot(&json!({}), 100);
        assert!(result["rate_limits"]["seven_day"].is_null());
        assert!(result["input_tokens"].is_null());
    }
    #[test]
    fn replaces_snapshot_atomically() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("claude-usage.json");
        save(&path, &snapshot(&json!({}), 100)).unwrap();
        save(&path, &snapshot(&json!({}), 200)).unwrap();
        let value: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        assert_eq!(value["updated_at"], 200);
    }
}
