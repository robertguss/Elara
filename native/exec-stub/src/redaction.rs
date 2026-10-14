pub struct Redactor {
    rules: Vec<(Vec<u8>, Vec<u8>)>,
    pending: Vec<u8>,
}

impl Redactor {
    pub fn new(mut rules: Vec<(Vec<u8>, Vec<u8>)>) -> Self {
        rules.sort_by(|a, b| b.0.len().cmp(&a.0.len()).then(a.1.cmp(&b.1)));
        Self {
            rules,
            pending: Vec::new(),
        }
    }

    pub fn feed(&mut self, bytes: &[u8], eof: bool) -> Vec<u8> {
        if self.rules.is_empty() {
            return bytes.to_vec();
        }
        self.pending.extend_from_slice(bytes);
        let mut output = Vec::with_capacity(self.pending.len());
        let mut at = 0;
        while at < self.pending.len() {
            let rest = &self.pending[at..];
            let mut matched = false;
            let mut incomplete = false;
            for (secret, replacement) in &self.rules {
                if !eof && rest.len() < secret.len() && secret.starts_with(rest) {
                    incomplete = true;
                    break;
                }
                if rest.starts_with(secret) {
                    output.extend_from_slice(replacement);
                    at += secret.len();
                    matched = true;
                    break;
                }
            }
            if incomplete {
                break;
            }
            if !matched {
                output.push(self.pending[at]);
                at += 1;
            }
        }
        self.pending.drain(..at);
        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literal_longest_matches_survive_every_chunk_boundary() {
        let input = b"before abcdef after abc then xyz\n123 xyz\n123 end";
        let expected = b"before [fnox:LONG] after [fnox:SHORT] then [fnox:MULTI] [fnox:MULTI] end";
        for split in 0..=input.len() {
            let mut redactor = Redactor::new(vec![
                (b"abc".to_vec(), b"[fnox:SHORT]".to_vec()),
                (b"abcdef".to_vec(), b"[fnox:LONG]".to_vec()),
                (b"xyz\n123".to_vec(), b"[fnox:MULTI]".to_vec()),
            ]);
            let mut output = redactor.feed(&input[..split], false);
            output.extend(redactor.feed(&input[split..], false));
            output.extend(redactor.feed(b"", true));
            assert_eq!(output, expected, "split {split}");
        }
    }

    #[test]
    fn bytewise_input_and_binary_neighbors_preserve_non_secrets() {
        let mut redactor = Redactor::new(vec![(b"abc".to_vec(), b"[fnox:X]".to_vec())]);
        let mut output = Vec::new();
        for byte in b"\xffabc\0ab" {
            output.extend(redactor.feed(&[*byte], false));
        }
        output.extend(redactor.feed(b"", true));
        assert_eq!(output, b"\xff[fnox:X]\0ab");
    }
}
