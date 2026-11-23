// SPDX-License-Identifier: MPL-2.0
//! Streaming text index plus lightweight OSC 133 command-output anchors.
//! The raw ANSI log remains authoritative; this index never replays TUI state.
#[derive(Default)]
pub struct HistoryIndexer {
    pending: Vec<u8>,
    escape: Escape,
    osc: Vec<u8>,
    anchors: Vec<(f64, usize)>,
}
#[derive(Default, Clone, Copy)]
enum Escape { #[default] Normal, Esc, Csi, Osc, OscEsc }
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
                    },
                    b'\r' => self.pending.clear(),
                    0x08 => { self.pending.pop(); },
                    b'\t' => self.pending.push(b' '),
                    0x20..=0x7e | 0x80..=0xff => self.pending.push(byte),
                    _ => {},
                },
                Escape::Esc => {
                    self.escape = match byte {
                        b'[' => Escape::Csi,
                        b']' => { self.osc.clear(); Escape::Osc },
                        _ => Escape::Normal,
                    };
                }
                Escape::Csi => if (0x40..=0x7e).contains(&byte) {
                    self.escape = Escape::Normal;
                },
                Escape::Osc => {
                    if byte == 7 { self.finish_osc(completed.len()); self.escape = Escape::Normal; }
                    else if byte == 0x1b { self.escape = Escape::OscEsc; }
                    else if self.osc.len() < 256 { self.osc.push(byte); }
                },
                Escape::OscEsc => {
                    if byte == b'\\' {
                        self.finish_osc(completed.len());
                        self.escape = Escape::Normal;
                    } else {
                        if self.osc.len() < 256 { self.osc.push(0x1b); self.osc.push(byte); }
                        self.escape = Escape::Osc;
                    }
                },
            }
            if self.pending.len() >= 16 * 1024 {
                completed.push(String::from_utf8_lossy(&self.pending).into_owned());
                self.pending.clear();
            }
        }
        completed
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
    #[test] fn ansi_is_not_indexed() {
        let mut h=HistoryIndexer::default();
        assert_eq!(h.ingest(b"abc\x1b[31mred\x1b[0m\n"), vec!["abcred"]);
    }
    #[test] fn split_ansi() {
        let mut h=HistoryIndexer::default();
        assert!(h.ingest(b"abc\x1b[").is_empty());
        assert_eq!(h.ingest(b"31mX\n"), vec!["abcX"]);
    }
    #[test] fn bound_no_newline() {
        let mut h=HistoryIndexer::default();
        assert_eq!(h.ingest(&vec![b'x'; 20000]).len(),1);
    }
    #[test] fn command_anchors_are_not_visible_and_can_span_chunks() {
        let mut h=HistoryIndexer::default();
        assert_eq!(h.ingest(b"prompt\n\x1b]133;C;1732"), vec!["prompt"]);
        assert!(h.take_anchors().is_empty());
        assert_eq!(h.ingest(b"000000.25\x07output\n"), vec!["output"]);
        assert_eq!(h.take_anchors(), vec![(1732000000.25, 0)]);
    }
    #[test] fn anchors_keep_the_correct_offset_inside_a_batch() {
        let mut h=HistoryIndexer::default();
        assert_eq!(h.ingest(b"before\n\x1b]133;C;1732000000.5\x1b\\result\n"), vec!["before","result"]);
        assert_eq!(h.take_anchors(), vec![(1732000000.5, 1)]);
    }
}
