//! 다른 앱에서 붙여 넣은 글을 이 앱의 마크다운 해석기가 읽을 수 있게 다듬는다 (Swift `PastedMarkdown.swift`).
//!
//! 노션 · 다른 편집기가 클립보드에 넣는 마크다운은 파일 형식과 조금씩 다르다.
//! - 들여쓰기 단위가 제각각이다 (노션·표준은 4칸, 탭, 이 앱 파일은 2칸).
//! - 목록 기호가 `•` · `◦` · `▪`처럼 글자로 들어오기도 하고, 체크박스가 `☐`/`☑`로 오기도 한다.
//! - 줄바꿈이 \r\n이거나, 공백 대신 줄바꿈 없는 공백(NBSP)이 섞여 있다.
//!
//! 파일 해석기를 느슨하게 만들면 저장된 메모를 잘못 읽을 위험이 있어, 붙여넣기에서만 손본다.

use crate::parser::{self, CODE_FENCE};
use crate::styled::StyledLine;
use crate::text::{self, chars};

pub fn parse(text: &str) -> Vec<StyledLine> {
    parser::parse(&normalize(text))
}

/// 파일 해석기가 바로 읽을 수 있는 꼴로 바꾼다. 코드 박스 안은 건드리지 않는다.
pub fn normalize(input: &str) -> String {
    let raw = text::replace_char(&text::replace_char(&text::replace_char(input, "\r\n", "\n"), "\r", "\n"), "\u{00A0}", " ");
    let mut lines = text::split_lines(&raw);
    // 클립보드 끝의 빈 줄 하나는 내용이 아니다. 남기면 붙여 넣을 때마다 빈 줄이 하나씩 생긴다.
    while lines.len() > 1 && text::trim_ws(lines[lines.len() - 1]).is_empty() {
        lines.pop();
    }

    let unit = indent_unit(&lines);
    let mut inside_code = false;
    let mapped: Vec<String> = lines
        .iter()
        .map(|line| {
            if text::has_prefix(text::trim_ws(line), CODE_FENCE) {
                inside_code = !inside_code;
                return text::trim_ws(line).to_string();
            }
            if inside_code {
                return line.to_string();
            }
            let (spaces, body) = split_indent(line);
            let marked = normalize_marker(&body);
            // 목록 줄만 단계로 다시 맞춘다. 문단의 들여쓰기는 그대로 둔다.
            if !is_list_line(&marked) {
                return " ".repeat(spaces) + &marked;
            }
            let level = if unit > 0 { spaces / unit } else { 0 };
            "  ".repeat(level) + &marked
        })
        .collect();
    mapped.join("\n")
}

/// 목록 줄 들여쓰기에서 한 단계가 몇 칸인지 찾는다. 가장 작은 0이 아닌 들여쓰기가 한 단계다.
fn indent_unit(lines: &[&str]) -> usize {
    let mut unit = 0usize;
    let mut inside_code = false;
    for line in lines {
        if text::has_prefix(text::trim_ws(line), CODE_FENCE) {
            inside_code = !inside_code;
            continue;
        }
        if inside_code {
            continue;
        }
        let (spaces, body) = split_indent(line);
        if spaces == 0 || !is_list_line(&normalize_marker(&body)) {
            continue;
        }
        unit = if unit == 0 { spaces } else { unit.min(spaces) };
    }
    unit
}

/// 앞쪽 공백 칸 수와 나머지. 탭 하나는 4칸으로 센다.
fn split_indent(line: &str) -> (usize, String) {
    use unicode_segmentation::UnicodeSegmentation;
    let mut spaces = 0usize;
    for (i, g) in line.grapheme_indices(true) {
        if text::ch_eq(g, " ") {
            spaces += 1;
        } else if text::ch_eq(g, "\t") {
            spaces += 4;
        } else {
            return (spaces, line[i..].to_string());
        }
    }
    (spaces, String::new())
}

/// 글자로 들어온 목록 · 체크박스 기호를 마크다운 기호로 바꾼다.
const MARKER_REPLACEMENTS: [(&str, &str); 13] = [
    ("☐ ", "- [ ] "), ("☑ ", "- [x] "), ("✅ ", "- [x] "),
    ("[ ] ", "- [ ] "), ("[x] ", "- [x] "), ("[X] ", "- [x] "),
    ("• ", "- "), ("◦ ", "- "), ("▪ ", "- "), ("▫ ", "- "), ("‣ ", "- "), ("⁃ ", "- "),
    ("❝ ", "> "),
];

fn normalize_marker(body: &str) -> String {
    for (from, to) in MARKER_REPLACEMENTS.iter() {
        if text::has_prefix(body, from) {
            return format!("{to}{}", text::drop_first(body, text::count(from)));
        }
    }
    // `* `·`+ ` 글머리와 `* [ ]` 체크박스도 표준 마크다운이다. 파일 해석기는 `- `만 체크박스로 읽는다.
    for star in ["* ", "+ "] {
        if text::has_prefix(body, star) {
            return format!("- {}", text::drop_first(body, 2));
        }
    }
    // `1)` 꼴 번호 목록 → `1.`
    let cs = chars(body);
    let digits = cs.iter().take_while(|c| text::is_number(c)).count();
    if digits > 0 {
        let after = text::drop_first(body, digits);
        if text::has_prefix(after, ") ") {
            return format!("{}. {}", cs[..digits].concat(), text::drop_first(body, digits + 2));
        }
    }
    body.to_string()
}

fn is_list_line(body: &str) -> bool {
    if text::has_prefix(body, "- ") || text::has_prefix(body, "* ") || text::has_prefix(body, "+ ") {
        return true;
    }
    // 1. 2. … 번호 목록
    let digits = chars(body).iter().take_while(|c| text::is_number(c)).count();
    if digits == 0 {
        return false;
    }
    let rest = text::drop_first(body, digits);
    text::has_prefix(rest, ". ") || text::has_prefix(rest, ") ")
}
