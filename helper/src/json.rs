//! Just enough JSON for the NDJSON protocol of DESIGN.md section 6.4 tier 2.
//!
//! Written by hand rather than pulled in, because the only dependency this crate is
//! allowed is `libc`: every other target in section 10.1 has to cross-compile from a
//! Linux box with no C toolchain, and a binary we upload over the user's own link is
//! built small.
//!
//! The one thing that needs care is that a server filename is **bytes**, not text
//! (section 5.4), and a JSON string is UTF-8 by definition. A path that is valid UTF-8
//! travels as `"path"`; one that is not travels as `"path_b64"`, base64 of the raw
//! bytes, and the agent decodes it back to the same bytes the index stores.

use std::fmt::Write as _;

/// Appends `"key":<json string>` for a byte path, choosing the field name by whether the
/// bytes are text. Returns the field name used, which the tests assert on.
pub fn write_path_field(out: &mut String, key: &str, bytes: &[u8]) -> &'static str {
    match std::str::from_utf8(bytes) {
        Ok(text) => {
            let _ = write!(out, "\"{}\":", key);
            write_string(out, text);
            "utf8"
        }
        Err(_) => {
            let _ = write!(out, "\"{}_b64\":", key);
            write_string(out, &base64(bytes));
            "b64"
        }
    }
}

/// A JSON string literal, with the two-character escapes JSON defines and `\u00XX` for
/// everything else below 0x20. A control character written raw makes the line
/// unparseable, and a filename may contain one.
pub fn write_string(out: &mut String, value: &str) {
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64(input: &[u8]) -> String {
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { ALPHABET[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { ALPHABET[n as usize & 63] as char } else { '=' });
    }
    out
}

pub fn base64_decode(input: &str) -> Option<Vec<u8>> {
    let mut value: u32 = 0;
    let mut bits = 0;
    let mut out = Vec::with_capacity(input.len() / 4 * 3);
    for c in input.bytes() {
        if c == b'=' || c == b'\n' || c == b'\r' {
            continue;
        }
        let index = ALPHABET.iter().position(|&a| a == c)? as u32;
        value = (value << 6) | index;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((value >> bits) as u8);
        }
    }
    Some(out)
}

// MARK: the parser, for the control lines the agent sends

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Value>),
    Object(Vec<(String, Value)>),
}

impl Value {
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Value::Array(items) => Some(items),
            _ => None,
        }
    }

    /// A list of paths as the agent sends them: plain strings, or `{"b64":"…"}` for a
    /// name whose bytes are not UTF-8.
    pub fn as_paths(&self) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        for item in self.as_array().unwrap_or(&[]) {
            match item {
                Value::String(s) => out.push(s.as_bytes().to_vec()),
                Value::Object(_) => {
                    if let Some(encoded) = item.get("b64").and_then(|v| v.as_str()) {
                        if let Some(bytes) = base64_decode(encoded) {
                            out.push(bytes);
                        }
                    }
                }
                _ => {}
            }
        }
        out
    }
}

pub fn parse(input: &str) -> Option<Value> {
    let bytes = input.as_bytes();
    let mut cursor = 0;
    let value = parse_value(bytes, &mut cursor)?;
    skip_space(bytes, &mut cursor);
    if cursor == bytes.len() {
        Some(value)
    } else {
        None
    }
}

fn skip_space(bytes: &[u8], cursor: &mut usize) {
    while *cursor < bytes.len() && (bytes[*cursor] as char).is_ascii_whitespace() {
        *cursor += 1;
    }
}

fn parse_value(bytes: &[u8], cursor: &mut usize) -> Option<Value> {
    skip_space(bytes, cursor);
    match *bytes.get(*cursor)? {
        b'{' => parse_object(bytes, cursor),
        b'[' => parse_array(bytes, cursor),
        b'"' => parse_string(bytes, cursor).map(Value::String),
        b't' => literal(bytes, cursor, "true", Value::Bool(true)),
        b'f' => literal(bytes, cursor, "false", Value::Bool(false)),
        b'n' => literal(bytes, cursor, "null", Value::Null),
        _ => parse_number(bytes, cursor),
    }
}

fn literal(bytes: &[u8], cursor: &mut usize, text: &str, value: Value) -> Option<Value> {
    if bytes[*cursor..].starts_with(text.as_bytes()) {
        *cursor += text.len();
        Some(value)
    } else {
        None
    }
}

fn parse_number(bytes: &[u8], cursor: &mut usize) -> Option<Value> {
    let start = *cursor;
    while *cursor < bytes.len()
        && matches!(bytes[*cursor], b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E')
    {
        *cursor += 1;
    }
    std::str::from_utf8(&bytes[start..*cursor])
        .ok()?
        .parse::<f64>()
        .ok()
        .map(Value::Number)
}

fn parse_string(bytes: &[u8], cursor: &mut usize) -> Option<String> {
    if bytes.get(*cursor) != Some(&b'"') {
        return None;
    }
    *cursor += 1;
    let mut out = String::new();
    loop {
        let c = *bytes.get(*cursor)?;
        *cursor += 1;
        match c {
            b'"' => return Some(out),
            b'\\' => {
                let escape = *bytes.get(*cursor)?;
                *cursor += 1;
                match escape {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'b' => out.push('\u{08}'),
                    b'f' => out.push('\u{0c}'),
                    b'u' => {
                        let hex = std::str::from_utf8(bytes.get(*cursor..*cursor + 4)?).ok()?;
                        *cursor += 4;
                        let code = u32::from_str_radix(hex, 16).ok()?;
                        out.push(char::from_u32(code)?);
                    }
                    _ => return None,
                }
            }
            _ => {
                // Multi-byte UTF-8 arrives byte by byte; collect the whole sequence.
                let extra = match c {
                    0x00..=0x7f => 0,
                    0xc0..=0xdf => 1,
                    0xe0..=0xef => 2,
                    0xf0..=0xf7 => 3,
                    _ => return None,
                };
                let slice = bytes.get(*cursor - 1..*cursor + extra)?;
                out.push_str(std::str::from_utf8(slice).ok()?);
                *cursor += extra;
            }
        }
    }
}

fn parse_array(bytes: &[u8], cursor: &mut usize) -> Option<Value> {
    *cursor += 1;
    let mut items = Vec::new();
    skip_space(bytes, cursor);
    if bytes.get(*cursor) == Some(&b']') {
        *cursor += 1;
        return Some(Value::Array(items));
    }
    loop {
        items.push(parse_value(bytes, cursor)?);
        skip_space(bytes, cursor);
        match *bytes.get(*cursor)? {
            b',' => *cursor += 1,
            b']' => {
                *cursor += 1;
                return Some(Value::Array(items));
            }
            _ => return None,
        }
    }
}

fn parse_object(bytes: &[u8], cursor: &mut usize) -> Option<Value> {
    *cursor += 1;
    let mut fields = Vec::new();
    skip_space(bytes, cursor);
    if bytes.get(*cursor) == Some(&b'}') {
        *cursor += 1;
        return Some(Value::Object(fields));
    }
    loop {
        skip_space(bytes, cursor);
        let key = parse_string(bytes, cursor)?;
        skip_space(bytes, cursor);
        if bytes.get(*cursor) != Some(&b':') {
            return None;
        }
        *cursor += 1;
        let value = parse_value(bytes, cursor)?;
        fields.push((key, value));
        skip_space(bytes, cursor);
        match *bytes.get(*cursor)? {
            b',' => *cursor += 1,
            b'}' => {
                *cursor += 1;
                return Some(Value::Object(fields));
            }
            _ => return None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_the_characters_that_would_break_a_line() {
        let mut out = String::new();
        write_string(&mut out, "a\"b\\c\nd\te\u{01}f");
        assert_eq!(out, "\"a\\\"b\\\\c\\nd\\te\\u0001f\"");
    }

    #[test]
    fn a_newline_in_a_filename_cannot_split_the_record() {
        let mut out = String::new();
        write_path_field(&mut out, "path", b"two\nlines.txt");
        assert_eq!(out, r#""path":"two\nlines.txt""#);
        assert_eq!(out.lines().count(), 1);
    }

    #[test]
    fn a_non_utf8_name_travels_base64_under_its_own_key() {
        let mut out = String::new();
        let kind = write_path_field(&mut out, "path", &[0x61, 0xff, 0xfe, 0x62]);
        assert_eq!(kind, "b64");
        assert_eq!(out, r#""path_b64":"Yf/+Yg==""#);
        assert_eq!(base64_decode("Yf/+Yg==").unwrap(), vec![0x61, 0xff, 0xfe, 0x62]);
    }

    #[test]
    fn base64_round_trips_every_length_class() {
        for len in 0..40usize {
            let bytes: Vec<u8> = (0..len).map(|i| (i * 37 % 256) as u8).collect();
            assert_eq!(base64_decode(&base64(&bytes)).unwrap(), bytes, "len {len}");
        }
    }

    #[test]
    fn parses_a_roots_control_line() {
        let line = r#"{"op":"roots","shallow":["a","b/c"],"recursive":[{"b64":"Yf8="}],"excluded":[]}"#;
        let value = parse(line).expect("parses");
        assert_eq!(value.get("op").and_then(|v| v.as_str()), Some("roots"));
        assert_eq!(
            value.get("shallow").unwrap().as_paths(),
            vec![b"a".to_vec(), b"b/c".to_vec()]
        );
        assert_eq!(value.get("recursive").unwrap().as_paths(), vec![vec![0x61, 0xff]]);
        assert!(value.get("excluded").unwrap().as_paths().is_empty());
    }

    #[test]
    fn rejects_a_truncated_line_rather_than_guessing() {
        assert!(parse(r#"{"op":"roots","shallow":["a"#).is_none());
        assert!(parse("").is_none());
        assert!(parse("{} trailing").is_none());
    }

    #[test]
    fn parses_escapes_and_unicode_back() {
        let value = parse(r#"{"p":"aé\n\"b\""}"#).unwrap();
        assert_eq!(value.get("p").unwrap().as_str(), Some("aé\n\"b\""));
    }
}
