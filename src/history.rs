// SPDX-License-Identifier: MPL-2.0
//! Streaming text index plus lightweight OSC 133 command-output anchors.
//! The raw ANSI log remains authoritative; this index never replays TUI state.
#[derive(Default)]
pub struct HistoryIndexer {
    pending: Vec<u8>,
    carriage_return: bool,
    escape: Escape,
    osc: Vec<u8>,
    anchors: Vec<(f64, usize)>,
}
#[derive(Default, Clone, Copy)]
enum Escape {
    #[default]
    Normal,
    Esc,
    Csi,
    Osc,
    OscEsc,
}
impl HistoryIndexer {
    pub fn ingest(&mut self, bytes: &[u8]) -> Vec<String> {
        let mut completed = Vec::new();
        self.anchors.clear();
        for &byte in bytes {
            match self.escape {
                Escape::Normal => match byte {
                    0x1b => self.escape = Escape::Esc,
                    b'\n' => {
                        completed.push(String::from_utf8_lossy(&self.pending).into_owned());
                        self.pending.clear();
                        self.carriage_return = false;
                    }
                    // PTYs normally emit CRLF. Keep the completed text until
                    // LF; only a printable replacement makes CR a progress-line
                    // overwrite. This state survives chunk boundaries and ANSI.
                    b'\r' => self.carriage_return = true,
                    0x08 => self.backspace(),
                    b'\t' => self.append_printable(b' '),
                    0x20..=0x7e | 0x80..=0xff => self.append_printable(byte),
                    _ => {}
                },
                Escape::Esc => {
                    self.escape = match byte {
                        b'[' => Escape::Csi,
                        b']' => {
                            self.osc.clear();
                            Escape::Osc
                        }
                        _ => Escape::Normal,
                    };
                }
                Escape::Csi => {
                    if (0x40..=0x7e).contains(&byte) {
                        self.escape = Escape::Normal;
                    }
                }
                Escape::Osc => {
                    if byte == 7 {
                        self.finish_osc(completed.len());
                        self.escape = Escape::Normal;
                    } else if byte == 0x1b {
                        self.escape = Escape::OscEsc;
                    } else if self.osc.len() < 256 {
                        self.osc.push(byte);
                    }
                }
                Escape::OscEsc => {
                    if byte == b'\\' {
                        self.finish_osc(completed.len());
                        self.escape = Escape::Normal;
                    } else {
                        if self.osc.len() < 256 {
                            self.osc.push(0x1b);
                            self.osc.push(byte);
                        }
                        self.escape = Escape::Osc;
                    }
                }
            }
            if self.pending.len() >= 16 * 1024 {
                completed.push(String::from_utf8_lossy(&self.pending).into_owned());
                self.pending.clear();
                self.carriage_return = false;
            }
        }
        completed
    }

    fn append_printable(&mut self, byte: u8) {
        if self.carriage_return {
            self.pending.clear();
            self.carriage_return = false;
        }
        self.pending.push(byte);
    }

    fn backspace(&mut self) {
        // CR has already moved the cursor to column zero. Do not turn a BS
        // there into a deletion from the end of the retained CRLF text.
        if self.carriage_return || self.pending.is_empty() {
            return;
        }
        let mut start = self.pending.len() - 1;
        while start > 0 && self.pending[start] & 0xc0 == 0x80 {
            start -= 1;
        }
        self.pending.truncate(start);
    }

    fn finish_osc(&mut self, completed_lines: usize) {
        if let Some(timestamp) = self.osc.strip_prefix(b"133;C;") {
            if let Ok(start) = std::str::from_utf8(timestamp).unwrap_or("").parse::<f64>() {
                if start.is_finite() && start > 0.0 {
                    self.anchors.push((start, completed_lines));
                }
            }
        }
        self.osc.clear();
    }

    pub fn take_anchors(&mut self) -> Vec<(f64, usize)> {
        std::mem::take(&mut self.anchors)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ansi_is_not_indexed() {
        let mut h = HistoryIndexer::default();
        assert_eq!(h.ingest(b"abc\x1b[31mred\x1b[0m\n"), vec!["abcred"]);
    }
    #[test]
    fn split_ansi() {
        let mut h = HistoryIndexer::default();
        assert!(h.ingest(b"abc\x1b[").is_empty());
        assert_eq!(h.ingest(b"31mX\n"), vec!["abcX"]);
    }
    #[test]
    fn bound_no_newline() {
        let mut h = HistoryIndexer::default();
        assert_eq!(h.ingest(&vec![b'x'; 20000]).len(), 1);
    }
    #[test]
    fn command_anchors_are_not_visible_and_can_span_chunks() {
        let mut h = HistoryIndexer::default();
        assert_eq!(h.ingest(b"prompt\n\x1b]133;C;1732"), vec!["prompt"]);
        assert!(h.take_anchors().is_empty());
        assert_eq!(h.ingest(b"000000.25\x07output\n"), vec!["output"]);
        assert_eq!(h.take_anchors(), vec![(1732000000.25, 0)]);
    }
    #[test]
    fn anchors_keep_the_correct_offset_inside_a_batch() {
        let mut h = HistoryIndexer::default();
        assert_eq!(
            h.ingest(b"before\n\x1b]133;C;1732000000.5\x1b\\result\n"),
            vec!["before", "result"]
        );
        assert_eq!(h.take_anchors(), vec![(1732000000.5, 1)]);
    }

    #[test]
    fn ordinary_pty_crlf_keeps_lines() {
        let mut h = HistoryIndexer::default();
        assert_eq!(
            h.ingest(b"command\r\nfirst\r\nsecond\r\n"),
            vec!["command", "first", "second"]
        );
        assert!(h.ingest(b"").is_empty());
    }

    #[test]
    fn crlf_can_span_chunks_without_duplicate_lines() {
        let mut h = HistoryIndexer::default();
        assert!(h.ingest(b"first\r").is_empty());
        assert_eq!(h.ingest(b"\nsecond\r"), vec!["first"]);
        assert_eq!(h.ingest(b"\n"), vec!["second"]);
        assert!(h.ingest(b"").is_empty());
    }

    #[test]
    fn bare_cr_replaces_progress_only_when_new_text_arrives() {
        let mut h = HistoryIndexer::default();
        assert!(h.ingest(b"Downloading 10%\r").is_empty());
        assert!(h.ingest(b"Downloading 20%\r").is_empty());
        assert_eq!(h.ingest(b"Done\r\n"), vec!["Done"]);
        assert_eq!(h.ingest(b"old\r\tnew\n"), vec![" new"]);
    }

    #[test]
    fn ansi_between_cr_and_lf_does_not_erase_text() {
        let mut h = HistoryIndexer::default();
        assert!(h.ingest(b"result\r\x1b[").is_empty());
        assert_eq!(h.ingest(b"0m\x1b]0;window title\x07\n"), vec!["result"]);
        assert_eq!(h.ingest(b"old\r\x1b[32mnew\x1b[0m\r\n"), vec!["new"]);
    }

    #[test]
    fn backspace_respects_carriage_return_and_utf8() {
        let mut h = HistoryIndexer::default();
        assert_eq!(h.ingest("café\x08e\r\n".as_bytes()), vec!["cafe"]);
        assert_eq!(h.ingest(b"retained\r\x08\n"), vec!["retained"]);
        assert_eq!(h.ingest(b"old\r\x08new\n"), vec!["new"]);
    }

    #[test]
    fn command_anchor_with_pty_line_endings_points_after_command() {
        let mut h = HistoryIndexer::default();
        assert_eq!(
            h.ingest(b"$ seq 1 3\r\n\x1b]133;C;1732000000.5\x071\r\n2\r\n3\r\n"),
            vec!["$ seq 1 3", "1", "2", "3"]
        );
        assert_eq!(h.take_anchors(), vec![(1732000000.5, 1)]);
        assert!(h.take_anchors().is_empty());
    }

    #[test]
    fn crlf_text_and_anchors_are_stable_at_every_chunk_boundary() {
        let stream =
            b"$ build\r\n\x1b]133;C;1732000000.5\x1b\\10%\r\x1b[32mDone\r\x1b[0m\nnext\r\n";
        for split in 0..=stream.len() {
            let mut h = HistoryIndexer::default();
            let mut lines = h.ingest(&stream[..split]);
            let mut anchors = h.take_anchors();
            let previous_lines = lines.len();
            lines.extend(h.ingest(&stream[split..]));
            anchors.extend(
                h.take_anchors()
                    .into_iter()
                    .map(|(time, offset)| (time, previous_lines + offset)),
            );
            assert_eq!(lines, vec!["$ build", "Done", "next"], "split at {split}");
            assert_eq!(anchors, vec![(1732000000.5, 1)], "split at {split}");
        }
    }
}
