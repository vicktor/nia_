// SPDX-License-Identifier: MPL-2.0
//! Bounded text-only index of streamed PTY output. Does not try to replay TUI
//! screen mutations, which remain in the original raw ANSI log.
#[derive(Default)]
pub struct HistoryIndexer {
    pending: Vec<u8>,
    escape: Escape,
}
#[derive(Default, Clone, Copy)]
enum Escape { #[default] Normal, Esc, Csi, Osc, OscEsc }
impl HistoryIndexer {
    pub fn ingest(&mut self, bytes: &[u8]) -> Vec<String> {
        let mut completed = Vec::new();
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
                Escape::Esc => self.escape = match byte {
                    b'[' => Escape::Csi, b']' => Escape::Osc, _ => Escape::Normal,
                },
                Escape::Csi => if (0x40..=0x7e).contains(&byte) { self.escape = Escape::Normal; },
                Escape::Osc => if byte == 7 { self.escape = Escape::Normal; }
                    else if byte == 0x1b { self.escape = Escape::OscEsc; },
                Escape::OscEsc => self.escape = if byte == b'\\' { Escape::Normal } else { Escape::Osc },
            }
            // Bound partial lines to avoid unbounded RAM on output without \n.
            if self.pending.len() >= 16 * 1024 {
                completed.push(String::from_utf8_lossy(&self.pending).into_owned());
                self.pending.clear();
            }
        }
        completed
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
}
