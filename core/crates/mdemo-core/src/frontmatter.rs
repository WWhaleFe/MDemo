use crate::{
    id::MemoID,
    link::{percent_decode, percent_encode, MemoLink, MemoLinkKind},
    meta::{clamp_alpha, MemoDate, MemoMeta},
};
use std::collections::{HashMap, HashSet};
use unicode_segmentation::UnicodeSegmentation;
#[derive(Clone, Debug, PartialEq)]
pub struct MemoDocument {
    pub meta: MemoMeta,
    pub body: String,
    pub unknown_frontmatter_lines: Vec<String>,
    pub unknown_link_tokens: Vec<String>,
}
/// Foundation의 whitespaces와 같은 가로 공백만 제거한다. 단독 CR은 남긴다.
pub fn trim(s: &str) -> &str {
    s.trim_matches(|c| {
        matches!(
            c,
            '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
                ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
        )
    })
}
/// Swift Character와 같은 확장 문자소 경계에서 구분자를 찾는다.
fn split<'a>(s: &'a str, delimiter: &str) -> Vec<&'a str> {
    let mut start = 0;
    let mut result = Vec::new();
    for (i, g) in s.grapheme_indices(true) {
        if g == delimiter {
            result.push(&s[start..i]);
            start = i + g.len();
        }
    }
    result.push(&s[start..]);
    result
}
pub fn unquote(s: &str) -> String {
    let glyphs: Vec<_> = s.graphemes(true).collect();
    if glyphs.len() < 2 || glyphs.first() != Some(&"\"") || glyphs.last() != Some(&"\"") {
        return s.into();
    }
    let mut chars = glyphs[1..glyphs.len() - 1].iter().copied();
    let mut out = String::new();
    while let Some(c) = chars.next() {
        if c == "\\" {
            if let Some(e) = chars.next() {
                match e {
                    "\\" | "\"" => out.push_str(e),
                    "n" => out.push('\n'),
                    "r" => out.push('\r'),
                    _ => {
                        out.push('\\');
                        out.push_str(e)
                    }
                }
            } else {
                out.push_str(c)
            }
        } else {
            out.push_str(c)
        }
    }
    out
}
pub fn quote(s: &str) -> String {
    let mut out = String::from("\"");
    for g in s.graphemes(true) {
        match g {
            "\\" => out.push_str("\\\\"),
            "\"" => out.push_str("\\\""),
            "\n" => out.push_str("\\n"),
            "\r" => out.push_str("\\r"),
            "\r\n" => out.push_str("\\r\\n"),
            _ => out.push_str(g),
        }
    }
    out.push('"');
    out
}
fn parse_link(s: &str) -> Option<MemoLink> {
    let tails: Vec<_> = split(trim(s), "~");
    let parts: Vec<_> = split(tails[0], ":").into_iter().map(trim).collect();
    if parts.len() != 2 {
        return None;
    }
    let kind = MemoLinkKind::ALL
        .into_iter()
        .find(|k| k.token() == parts[0])?;
    let to = MemoID::new(parts[1]);
    if !to.is_valid() {
        return None;
    }
    let decoded = tails.get(1).and_then(|s| percent_decode(s));
    let broken = tails.len() > 1 && decoded.is_none();
    let suffix = if broken {
        format!("~{}", tails[1..].join("~"))
    } else if tails.len() > 2 {
        format!("~{}", tails[2..].join("~"))
    } else {
        String::new()
    };
    Some(MemoLink {
        to,
        kind,
        label: MemoLink::normalize_label(&decoded.unwrap_or_default()),
        unknown_suffix: suffix,
        preserves_raw_label: if broken { Some(true) } else { None },
    })
}

fn number(v: f64) -> String {
    if v.is_nan() {
        return "nan".into();
    }
    if v == v.round() && v.abs() < 1e6 {
        return format!("{v:.1}");
    }
    // C의 %g 기본 정밀도는 유효 숫자 여섯 자리다.
    let s = format!("{v:.5e}");
    let (mantissa, exp) = s.split_once('e').unwrap();
    let exp: i32 = exp.parse().unwrap();
    if !(-4..6).contains(&exp) {
        format!(
            "{}e{}{:#02}",
            mantissa.trim_end_matches('0').trim_end_matches('.'),
            if exp < 0 { "-" } else { "+" },
            exp.abs()
        )
    } else {
        format!("{:.*}", (5 - exp).max(0) as usize, v)
            .trim_end_matches('0')
            .trim_end_matches('.')
            .to_string()
    }
}
pub fn decode(text: &str) -> Result<MemoDocument, String> {
    let text = text.replace("\r\n", "\n");
    let lines: Vec<_> = text.split('\n').collect();
    if lines.first().map(|s| trim(s)) != Some("---") {
        return Err("여는 구분자 없음".into());
    }
    let close = (1..lines.len())
        .find(|i| trim(lines[*i]) == "---")
        .ok_or("닫는 구분자 없음")?;
    let known = [
        "schemaVersion",
        "id",
        "title",
        "group",
        "color",
        "bgAlpha",
        "textAlpha",
        "open",
        "pinned",
        "created",
        "modified",
        "conflictOf",
        "links",
        "locked",
        "lockSalt",
        "lockIterations",
        "lockVersion",
        "lockFailures",
    ];
    let mut fields = HashMap::new();
    let mut unknown = Vec::new();
    for line in &lines[1..close] {
        if let Some((index, _)) = line.grapheme_indices(true).find(|(_, g)| *g == ":") {
            let (key, value) = (&line[..index], &line[index + 1..]);
            let key = trim(key);
            if !key.is_empty() && !key.starts_with('#') && known.contains(&key) {
                fields.insert(key, unquote(trim(value)));
                continue;
            }
        }
        if !trim(line).is_empty() {
            unknown.push((*line).into())
        }
    }
    let get = |k| fields.get(k).cloned();
    let nonempty = |k| get(k).filter(|s| !s.is_empty());
    let integer = |k| get(k).and_then(|s| s.parse::<i64>().ok());
    let boolean = |k, default| {
        get(k)
            .and_then(|s| match s.to_lowercase().as_str() {
                "true" | "yes" | "1" => Some(true),
                "false" | "no" | "0" => Some(false),
                _ => None,
            })
            .unwrap_or(default)
    };
    let id = MemoID::new(get("id").ok_or("필수 id 없음")?);
    if !id.is_valid() {
        return Err("유효하지 않은 id".into());
    }
    let created = get("created")
        .and_then(|s| MemoDate::parse(&s))
        .unwrap_or_else(|| MemoDate::now());
    let modified = get("modified")
        .and_then(|s| MemoDate::parse(&s))
        .unwrap_or_else(|| created);
    let mut links = Vec::new();
    let mut unknown_tokens = Vec::new();
    let mut seen = HashSet::new();
    if let Some(value) = get("links") {
        for token in split(&value, ",") {
            if let Some(link) = parse_link(token) {
                if seen.insert(link.clone()) {
                    links.push(link)
                }
            } else if !trim(token).is_empty() {
                unknown_tokens.push(token.into())
            }
        }
    }
    Ok(MemoDocument {
        meta: MemoMeta {
            schema_version: integer("schemaVersion").unwrap_or(3).max(3),
            id,
            title: nonempty("title"),
            group: nonempty("group"),
            color_hex: get("color").unwrap_or("#FFF3B0".into()),
            background_alpha: clamp_alpha(
                get("bgAlpha").and_then(|s| s.parse().ok()).unwrap_or(0.95),
                0.15,
            ),
            text_alpha: clamp_alpha(
                get("textAlpha").and_then(|s| s.parse().ok()).unwrap_or(1.),
                0.3,
            ),
            is_open: boolean("open", true),
            is_pinned: boolean("pinned", true),
            created,
            modified,
            conflict_of: get("conflictOf").map(MemoID::new),
            links,
            is_locked: boolean("locked", false),
            lock_salt: get("lockSalt"),
            lock_iterations: integer("lockIterations"),
            lock_version: integer("lockVersion"),
            lock_failures: integer("lockFailures"),
        },
        body: lines[close + 1..].join("\n"),
        unknown_frontmatter_lines: unknown,
        unknown_link_tokens: unknown_tokens,
    })
}
pub fn encode(d: &MemoDocument) -> String {
    let m = &d.meta;
    let mut lines = vec![
        "---".into(),
        format!("schemaVersion: {}", m.schema_version),
        format!("id: {}", m.id.raw_value),
    ];
    for (key, value) in [("title", &m.title), ("group", &m.group)] {
        if let Some(s) = value.as_ref().filter(|s| !s.is_empty()) {
            lines.push(format!("{key}: {}", quote(s)))
        }
    }
    lines.extend([
        format!("color: {}", quote(&m.color_hex)),
        format!("bgAlpha: {}", number(m.background_alpha)),
        format!("textAlpha: {}", number(m.text_alpha)),
        format!("open: {}", m.is_open),
        format!("pinned: {}", m.is_pinned),
    ]);
    if m.is_locked {
        lines.push("locked: true".into())
    }
    if let Some(s) = &m.lock_salt {
        lines.push(format!("lockSalt: {s}"))
    }
    for (key, value) in [
        ("lockIterations", m.lock_iterations),
        ("lockVersion", m.lock_version),
        ("lockFailures", m.lock_failures),
    ] {
        if let Some(v) = value {
            lines.push(format!("{key}: {v}"))
        }
    }
    lines.extend([
        format!("created: {}", m.created.iso8601()),
        format!("modified: {}", m.modified.iso8601()),
    ]);
    if let Some(id) = &m.conflict_of {
        lines.push(format!("conflictOf: {}", id.raw_value))
    }
    let mut tokens: Vec<_> = m
        .links
        .iter()
        .map(|l| {
            format!(
                "{}:{}{}{}",
                l.kind.token(),
                l.to.raw_value,
                if l.label.is_empty()
                    && (l.unknown_suffix.is_empty() || l.preserves_raw_label == Some(true))
                {
                    String::new()
                } else {
                    format!("~{}", percent_encode(&l.label))
                },
                l.unknown_suffix
            )
        })
        .collect();
    tokens.extend(d.unknown_link_tokens.clone());
    if !tokens.is_empty() {
        lines.push(format!("links: {}", tokens.join(",")))
    }
    lines.extend(d.unknown_frontmatter_lines.clone());
    lines.push("---".into());
    lines.push(d.body.clone());
    lines.join("\n")
}
#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(extra: &str) -> String {
        format!("---\nid: 01ARZ3NDEKTSV4RRFFQ69G5F00\ncreated: 2026-01-01T00:00:00Z\n{extra}\n---\nbody\rrest")
    }
    #[test]
    fn quotes_once() {
        for s in ["a\\n", "a\n", "a\\\"b", "a\r", "한😀"] {
            assert_eq!(unquote(&quote(s)), s)
        }
    }
    #[test]
    fn hidden_lines_crlf_alpha() {
        let d = decode(
            &fixture("# comment\nunknown\nbgAlpha: nan\ntextAlpha: 0").replace('\n', "\r\n"),
        )
        .unwrap();
        assert!(d.meta.background_alpha.is_nan());
        assert_eq!(d.meta.text_alpha, 0.3);
        assert_eq!(d.unknown_frontmatter_lines, vec!["# comment", "unknown"]);
        assert!(encode(&d).ends_with("body\rrest"));
        assert_eq!(trim("\t a\r "), "a\r");
    }
    #[test]
    fn broken_label_and_dedup() {
        let d=decode(&fixture("links: flow:01ARZ3NDEKTSV4RRFFQ69G5F00~%ZZ~future,flow:01ARZ3NDEKTSV4RRFFQ69G5F00~%ZZ~future,bad")).unwrap();
        assert_eq!(d.meta.links.len(), 1);
        assert_eq!(d.meta.links[0].preserves_raw_label, Some(true));
        assert!(encode(&d).contains("~%ZZ~future,bad"));
    }
    #[test]
    fn migration_date_and_numbers() {
        let d = decode(&fixture(
            "schemaVersion: 1\nmodified: 2026-01-01T09:00:00.123+09:00",
        ))
        .unwrap();
        assert_eq!(d.meta.schema_version, 3);
        assert_eq!(d.meta.modified.iso8601(), "2026-01-01T00:00:00.123Z");
        assert_eq!(number(0.12345678), "0.123457");
        assert_eq!(number(1.), "1.0");
        assert!(decode("---\nid: lower\n---").is_err());
    }
}
#[cfg(test)]
mod character_tests {
    use super::*;
    #[test]
    fn combining_marks_on_escape_and_separator() {
        assert_eq!(unquote("\"\\n\u{301}\""), "\\n\u{301}");
        assert_eq!(quote("\"\u{301}\\\u{301}"), "\"\"\u{301}\\\u{301}\"");
        assert_eq!(quote("\r\n"), "\"\\r\\n\"");
        let d=decode("---\nid: 01ARZ3NDEKTSV4RRFFQ69G5F00\ncreated: 2001-01-01T00:00:00Z\ntitle:\u{301}unknown\n---\n").unwrap();
        assert!(d.meta.title.is_none());
        assert_eq!(d.unknown_frontmatter_lines, vec!["title:\u{301}unknown"]);
    }
}
