//! 글자 인식 결과를 메모에 넣을 글로 바꾼다 (Swift `OCRMarkdownBuilder.swift`, 순수 함수).
//!
//! 같은 높이의 조각은 한 줄로 합치고, 줄 간격이 벌어지면 문단을 나눈다.
//! 마크다운 모드에서는 글자 크기로 제목을, 줄머리 기호로 목록 · 번호 · 체크를 알아본다.
//! 좌표는 이미지 전체를 0~1로 본 정규화 좌표이고, Vision처럼 원점이 왼쪽 아래다(`y`가 클수록 위쪽).

use crate::text::{self, chars};

/// 글자 인식이 돌려준 조각 하나.
#[derive(Clone, Debug, PartialEq)]
pub struct OcrLine {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub confidence: f64,
}

impl OcrLine {
    pub fn new(text: &str, x: f64, y: f64, width: f64, height: f64) -> Self {
        OcrLine { text: text.to_string(), x, y, width, height, confidence: 1.0 }
    }

    fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OcrMode {
    Markdown,
    Plain,
}

/// 제목으로 볼 줄 높이 배율 (본문 중앙값 기준).
const HEADING1_RATIO: f64 = 1.45;
const HEADING2_RATIO: f64 = 1.2;
/// 이 배율을 넘는 줄 간격은 문단 나눔이다.
const PARAGRAPH_GAP_RATIO: f64 = 1.6;
/// 본문 왼쪽 끝에서 줄 높이의 이 배율 이상 안쪽이면 하위 목록이다.
const INDENT_RATIO: f64 = 1.5;

struct Row {
    text: String,
    x: f64,
    mid_y: f64,
    height: f64,
}

pub fn build(lines: &[OcrLine], mode: OcrMode) -> String {
    let rows = merge_rows(lines);
    if rows.is_empty() {
        return String::new();
    }

    let heights: Vec<f64> = rows.iter().map(|r| r.height).collect();
    let body_height = median(&heights).unwrap_or(0.0);
    let spacings: Vec<f64> = rows.windows(2).map(|w| w[0].mid_y - w[1].mid_y).filter(|s| *s > 0.0).collect();
    let typical_spacing = median(&spacings);
    let min_x = rows.iter().map(|r| r.x).fold(None, |m: Option<f64>, x| Some(m.map_or(x, |m| if x < m { x } else { m }))).unwrap_or(0.0);

    let mut output: Vec<String> = Vec::new();
    for (index, row) in rows.iter().enumerate() {
        if index > 0 {
            if let Some(typical) = typical_spacing {
                if rows[index - 1].mid_y - row.mid_y > typical * PARAGRAPH_GAP_RATIO {
                    output.push(String::new());
                }
            }
        }
        match mode {
            OcrMode::Plain => output.push(row.text.clone()),
            OcrMode::Markdown => output.push(markdown_line(row, body_height, min_x)),
        }
    }
    output.join("\n")
}

// MARK: - 줄 합치기

/// 위에서 아래로, 같은 높이의 조각은 왼쪽부터 한 줄로 묶는다.
fn merge_rows(lines: &[OcrLine]) -> Vec<Row> {
    let mut sorted: Vec<&OcrLine> = lines.iter().filter(|l| !text::trim_ws(&l.text).is_empty()).collect();
    // Swift `sorted { $0.midY > $1.midY }`. 정렬은 안정적이다.
    sorted.sort_by(|a, b| b.mid_y().partial_cmp(&a.mid_y()).unwrap_or(std::cmp::Ordering::Equal));

    let mut groups: Vec<Vec<&OcrLine>> = Vec::new();
    for fragment in sorted {
        if let Some(last) = groups.last_mut() {
            let average_mid = last.iter().map(|l| l.mid_y()).fold(0.0, |a, b| a + b) / last.len() as f64;
            let row_height = swift_max(max_of(last.iter().map(|l| l.height)).unwrap_or(0.0), fragment.height);
            if (fragment.mid_y() - average_mid).abs() <= row_height * 0.5 {
                last.push(fragment);
                continue;
            }
        }
        groups.push(vec![fragment]);
    }

    groups
        .into_iter()
        .map(|group| {
            let mut ordered = group.clone();
            ordered.sort_by(|a, b| a.x.partial_cmp(&b.x).unwrap_or(std::cmp::Ordering::Equal));
            let pieces: Vec<&str> = ordered.iter().map(|l| text::trim_ws(&l.text)).filter(|t| !t.is_empty()).collect();
            Row {
                text: pieces.join(" "),
                x: ordered.first().map_or(0.0, |l| l.x),
                mid_y: group.iter().map(|l| l.mid_y()).fold(0.0, |a, b| a + b) / group.len() as f64,
                height: max_of(group.iter().map(|l| l.height)).unwrap_or(0.0),
            }
        })
        .collect()
}

fn max_of(values: impl Iterator<Item = f64>) -> Option<f64> {
    values.fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| if v > m { v } else { m })))
}

/// Swift `max(a, b)`: b가 a 이상일 때 b.
fn swift_max(a: f64, b: f64) -> f64 {
    if b >= a { b } else { a }
}

// MARK: - 마크다운

fn markdown_line(row: &Row, body_height: f64, min_x: f64) -> String {
    if body_height > 0.0 {
        let ratio = row.height / body_height;
        if ratio >= HEADING1_RATIO {
            return format!("# {}", row.text);
        }
        if ratio >= HEADING2_RATIO {
            return format!("## {}", row.text);
        }
    }
    let Some(converted) = list_line(&row.text) else { return row.text.clone() };
    let is_nested = row.height > 0.0 && row.x - min_x >= row.height * INDENT_RATIO;
    format!("{}{converted}", if is_nested { "  " } else { "" })
}

const UNCHECKED_MARKS: [&str; 3] = ["☐", "□", "▢"];
const CHECKED_MARKS: [&str; 5] = ["☑", "✓", "✔", "☒", "■"];
const BULLET_MARKS: [&str; 4] = ["•", "·", "▪", "◦"];
const CIRCLED_NUMBERS: [&str; 10] = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"];

fn mark_in(set: &[&str], first: &str) -> bool {
    set.iter().any(|m| text::ch_eq(first, m))
}

/// 줄머리 기호를 마크다운 목록 표기로 바꾼다. 목록이 아니면 None.
pub fn list_line(text_in: &str) -> Option<String> {
    let cs = chars(text_in);
    let first = *cs.first()?;
    let rest = text::trim_ws(&cs[1..].concat()).to_string();

    if mark_in(&UNCHECKED_MARKS, first) {
        return Some(format!("- [ ] {rest}"));
    }
    if mark_in(&CHECKED_MARKS, first) {
        return Some(format!("- [x] {rest}"));
    }
    if mark_in(&BULLET_MARKS, first) {
        return Some(format!("- {rest}"));
    }
    // 영문 하이픈 · 별표는 "-5도" 같은 글과 헷갈리므로 뒤에 공백이 있을 때만 목록으로 본다.
    if text::ch_eq(first, "-") || text::ch_eq(first, "*") {
        if !cs.get(1).is_some_and(|c| text::ch_eq(c, " ")) {
            return None;
        }
        return Some(format!("- {rest}"));
    }
    if let Some(index) = CIRCLED_NUMBERS.iter().position(|m| text::ch_eq(first, m)) {
        return Some(format!("{}. {rest}", index + 1));
    }

    // Swift는 ICU 정규식 `^(\d{1,3})[.)](?:\s+|$)`를 쓴다. 앞의 십진 숫자가 1~3개이고 바로 뒤가 `.`나 `)`,
    // 그 뒤가 공백(한 칸 이상)이거나 글 끝이어야 한다.
    let digits_end = text_in.find(|c: char| !text::is_decimal(c)).unwrap_or(text_in.len());
    let digit_count = text_in[..digits_end].chars().count();
    if !(1..=3).contains(&digit_count) {
        return None;
    }
    let after = &text_in[digits_end..];
    let tail = after.strip_prefix('.').or_else(|| after.strip_prefix(')'))?;
    let body = tail.trim_start_matches(text::is_regex_space);
    if body.len() == tail.len() && !tail.is_empty() {
        return None;
    }
    Some(format!("{}. {}", &text_in[..digits_end], text::trim_ws(body)))
}

fn median(values: &[f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = sorted.len() / 2;
    Some(if sorted.len() % 2 == 1 { sorted[mid] } else { (sorted[mid - 1] + sorted[mid]) / 2.0 })
}
