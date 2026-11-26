//! 마크다운 문자열을 서식 표현으로 되돌린다 (Swift `MarkdownParser.swift`). 파일을 열 때 쓴다.
//!
//! `serializer`와 짝을 이루며, 왕복해도 내용이 변하지 않아야 한다.
//! 글자 단위 비교는 Swift `Character`(확장 문자소, 정규 동치)와 같게 `text` 도우미를 거친다.

use crate::styled::*;
use crate::table;
use crate::text::{self, chars};

/// 코드 박스의 울타리 기호 (MD-10).
pub const CODE_FENCE: &str = "```";

pub fn parse(markdown: &str) -> Vec<StyledLine> {
    let mut lines = Vec::new();
    let mut inside_code_block = false;
    let normalized = text::replace_char(markdown, "\r\n", "\n");
    for raw in text::split_lines(&normalized) {
        // 울타리 줄 자체는 화면에 남기지 않는다. 마크다운 기호는 숨긴다는 원칙 그대로다 (MD-01).
        if text::has_prefix(text::trim_ws(raw), CODE_FENCE) {
            inside_code_block = !inside_code_block;
            continue;
        }
        if inside_code_block {
            // 코드 안의 `*`나 `#`는 서식이 아니라 코드다. 인라인 해석을 하지 않는다.
            lines.push(StyledLine::with_text(BlockStyle::CodeBlock, raw));
            continue;
        }
        // 표의 구분 줄은 문법이지 내용이 아니다. 화면에서 빼고 저장할 때 다시 만든다 (MD-14).
        if table::is_separator_row(raw) {
            continue;
        }
        lines.push(parse_line(raw));
    }
    lines
}

pub fn parse_line(line: &str) -> StyledLine {
    let (block, content) = parse_block(line);
    StyledLine { block, spans: parse_inline(&content) }
}

// MARK: - 블록

fn parse_block(line: &str) -> (BlockStyle, String) {
    let indent_level = count_indent(line);
    let trimmed = drop_indent(line);

    if text::str_eq(trimmed, "---") {
        return (BlockStyle::Divider, String::new());
    }

    // 이미지: 줄 전체가 `![설명](경로 =너비)`일 때만이다 (IMG-08).
    if let Some(image) = MarkdownImage::parse(trimmed) {
        return (BlockStyle::Image(image), String::new());
    }

    // 제목: # ~ ###### (들여쓰기 없음)
    if indent_level == 0 && text::has_prefix(trimmed, "#") {
        let cs = chars(trimmed);
        let mut level = 0usize;
        while level < cs.len() && text::ch_eq(cs[level], "#") && level < 6 {
            level += 1;
        }
        if level < cs.len() && text::ch_eq(cs[level], " ") {
            return (BlockStyle::Heading { level: level as i64 }, cs[level + 1..].concat());
        }
    }

    // 체크박스가 글머리 기호보다 먼저다 - "- [ ]"는 "- "로도 읽히기 때문이다.
    for (marker, checked) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] {
        if text::has_prefix(trimmed, marker) {
            return (BlockStyle::Checkbox { indent: indent_level, checked }, text::drop_first(trimmed, 6).to_string());
        }
    }

    if text::has_prefix(trimmed, "- ") || text::has_prefix(trimmed, "* ") {
        return (BlockStyle::Bullet { indent: indent_level }, text::drop_first(trimmed, 2).to_string());
    }

    if let Some((number, rest)) = parse_ordered_marker(trimmed) {
        return (BlockStyle::Ordered { indent: indent_level, number }, rest);
    }

    if text::has_prefix(trimmed, "> ") {
        return (BlockStyle::Quote, text::drop_first(trimmed, 2).to_string());
    }

    // 표는 세로줄이 곧 내용이다. 기호를 벗기지 않고 줄 전체를 그대로 둔다 (MD-14).
    if table::is_row(trimmed) {
        return (BlockStyle::TableRow, trimmed.to_string());
    }

    (BlockStyle::Paragraph, line.to_string())
}

/// 앞쪽 공백 · 탭 문자소를 뗀 나머지.
fn drop_indent(line: &str) -> &str {
    use unicode_segmentation::UnicodeSegmentation;
    for (i, g) in line.grapheme_indices(true) {
        if !(text::ch_eq(g, " ") || text::ch_eq(g, "\t")) {
            return &line[i..];
        }
    }
    ""
}

/// 들여쓰기 한 단계 = 공백 2칸. 탭 하나도 한 단계로 센다.
fn count_indent(line: &str) -> i64 {
    let mut spaces = 0i64;
    for g in chars(line) {
        if text::ch_eq(g, " ") {
            spaces += 1;
        } else if text::ch_eq(g, "\t") {
            spaces += 2;
        } else {
            break;
        }
    }
    spaces / 2
}

fn parse_ordered_marker(line: &str) -> Option<(i64, String)> {
    let cs = chars(line);
    let mut end = 0;
    while end < cs.len() && text::is_number(cs[end]) {
        end += 1;
    }
    if end == 0 {
        return None;
    }
    // Swift `Int(digits)`: 글자 하나라도 ASCII 숫자가 아니면 읽지 못한다.
    let number = text::parse_int(&cs[..end].concat())?;
    if end >= cs.len() || !text::ch_eq(cs[end], ".") {
        return None;
    }
    let after_dot = end + 1;
    if after_dot >= cs.len() || !text::ch_eq(cs[after_dot], " ") {
        return None;
    }
    Some((number, cs[after_dot + 1..].concat()))
}

// MARK: - 인라인

/// 바깥쪽 기호부터 벗겨 낸다. 직렬화가 감싼 순서(굵게 → 기울임 → 취소선 → 형광 → 코드)의 역순이다.
pub fn parse_inline(text: &str) -> Vec<StyledSpan> {
    if text.is_empty() {
        return vec![];
    }
    let mut spans = Vec::new();
    let format = StyledSpan::plain("");
    append_spans(&chars(text), &format, &mut spans);
    merge_adjacent(spans)
}

/// 긴 기호를 먼저 검사한다. `***`(굵게+기울임)를 `**`로 잡으면
/// 남은 `*` 하나가 짝을 잃어 저장할 때마다 기호가 늘어난다.
const DELIMITERS: [(&str, InlineStyleTag); 6] = [
    ("***", InlineStyleTag(InlineStyleTag::BOLD.0 | InlineStyleTag::ITALIC.0)),
    ("**", InlineStyleTag::BOLD),
    ("~~", InlineStyleTag::STRIKETHROUGH),
    ("==", InlineStyleTag::HIGHLIGHT),
    ("`", InlineStyleTag::CODE),
    ("*", InlineStyleTag::ITALIC),
];

/// `format`은 바깥에서 물려받은 서식이다. 글자는 비어 있고 서식만 쓴다.
fn append_spans(characters: &[&str], format: &StyledSpan, spans: &mut Vec<StyledSpan>) {
    let styles = format.styles;
    let mut index = 0usize;
    let mut plain: Vec<&str> = Vec::new();

    let flush = |plain: &mut Vec<&str>, spans: &mut Vec<StyledSpan>| {
        if !plain.is_empty() {
            let mut span = format.clone();
            span.text = plain.concat();
            spans.push(span);
            plain.clear();
        }
    };

    'outer: while index < characters.len() {
        // 색 태그 (<span style="color:…">, <mark style="background:…">). 코드 안에서는 글자일 뿐이다.
        if !styles.contains(InlineStyleTag::CODE) && text::ch_eq(characters[index], "<") {
            if let Some(tag) = match_color_tag(characters, index) {
                let closing_marker = chars(tag.closing);
                if let Some(closing) = find_closing(characters, index + tag.opening_length, &closing_marker) {
                    flush(&mut plain, spans);
                    let mut inner = format.clone();
                    if tag.is_highlight {
                        inner.styles.insert(InlineStyleTag::HIGHLIGHT);
                        inner.highlight_color = Some(tag.hex.clone());
                    } else {
                        inner.text_color = Some(tag.hex.clone());
                    }
                    append_spans(&characters[index + tag.opening_length..closing], &inner, spans);
                    index = closing + closing_marker.len();
                    continue 'outer;
                }
            }
        }

        for (marker, style) in DELIMITERS {
            // 코드 구간 안에서는 다른 기호를 서식으로 보지 않는다.
            if styles.contains(InlineStyleTag::CODE) && style != InlineStyleTag::CODE {
                continue;
            }
            if styles.contains(style) {
                continue;
            }
            let marker = chars(marker);
            if !matches(characters, index, &marker) {
                continue;
            }
            if let Some(closing) = find_closing(characters, index + marker.len(), &marker) {
                flush(&mut plain, spans);
                let mut inner_format = format.clone();
                inner_format.styles = styles.union(style);
                append_spans(&characters[index + marker.len()..closing], &inner_format, spans);
                index = closing + marker.len();
                continue 'outer;
            }
        }
        plain.push(characters[index]);
        index += 1;
    }
    flush(&mut plain, spans);
}

struct ColorTag {
    is_highlight: bool,
    hex: String,
    opening_length: usize,
    closing: &'static str,
}

/// 여는 색 태그를 읽는다. 앱이 쓰는 꼴 말고도, 다른 도구가 흔히 쓰는 꼴
/// (`background-color:`, 따옴표 종류, 공백, 소문자)까지는 받아 준다.
///
/// Swift는 ICU 정규식 `^<(span|mark)\s+style\s*=\s*["']\s*(color|background|background-color)\s*:\s*(#?[0-9A-Fa-f]{6})\s*;?\s*["']\s*>`를
/// 앞 64문자소 창에 적용한다. 되돌아가기가 결과를 바꾸지 않는 꼴이라 같은 순서로 직접 읽는다.
fn match_color_tag(characters: &[&str], index: usize) -> Option<ColorTag> {
    // 태그는 길지 않다. 줄 끝까지 넘기지 않고 앞부분만 본다.
    let window: String = characters[index..characters.len().min(index + 64)].concat();
    let mut cur = Cursor { s: &window, pos: 0 };
    cur.literal("<")?;
    let tag = if cur.literal("span").is_some() {
        "span"
    } else if cur.literal("mark").is_some() {
        "mark"
    } else {
        return None;
    };
    cur.spaces(1)?;
    cur.literal("style")?;
    cur.spaces(0)?;
    cur.literal("=")?;
    cur.spaces(0)?;
    cur.quote()?;
    cur.spaces(0)?;
    // `background-color`가 `background`보다 길다. 정규식 선택은 앞에서부터 시도하고 뒤가 안 맞으면 되돌아간다.
    let property_start = cur.pos;
    let mut property = None;
    for candidate in ["color", "background", "background-color"] {
        cur.pos = property_start;
        if cur.literal(candidate).is_none() {
            continue;
        }
        let after_property = cur.pos;
        cur.spaces(0)?;
        if cur.literal(":").is_some() {
            property = Some(candidate);
            break;
        }
        cur.pos = after_property;
    }
    let property = property?;
    cur.spaces(0)?;
    let hex_start = cur.pos;
    cur.literal("#");
    let digits_start = cur.pos;
    for _ in 0..6 {
        let c = cur.s[cur.pos..].chars().next()?;
        if !c.is_ascii_hexdigit() {
            return None;
        }
        cur.pos += 1;
    }
    let _ = digits_start;
    let hex = &window[hex_start..cur.pos];
    cur.spaces(0)?;
    cur.literal(";");
    cur.spaces(0)?;
    cur.quote()?;
    cur.spaces(0)?;
    cur.literal(">")?;

    let is_highlight = tag == "mark";
    // <span style="color">만 글자 색, <mark style="background">만 형광펜으로 본다.
    if is_highlight != property.starts_with("background") {
        return None;
    }
    // Swift는 일치한 구간의 문자소 수를 센다(구간 끝이 문자소 한가운데면 그 문자소까지 한 글자로 센다).
    let opening_length = text::count(&window[..cur.pos]);
    Some(ColorTag {
        is_highlight,
        hex: InlineColor::normalized(Some(hex))?,
        opening_length,
        closing: if is_highlight { "</mark>" } else { "</span>" },
    })
}

/// 정규식 조각을 앞에서부터 읽는 작은 커서.
struct Cursor<'a> {
    s: &'a str,
    pos: usize,
}

impl Cursor<'_> {
    fn literal(&mut self, lit: &str) -> Option<()> {
        if self.s[self.pos..].starts_with(lit) {
            self.pos += lit.len();
            Some(())
        } else {
            None
        }
    }

    /// `\s{min,}` (White_Space). 최소 개수를 못 채우면 None.
    fn spaces(&mut self, min: usize) -> Option<()> {
        let mut n = 0;
        while let Some(c) = self.s[self.pos..].chars().next() {
            if !text::is_regex_space(c) {
                break;
            }
            self.pos += c.len_utf8();
            n += 1;
        }
        (n >= min).then_some(())
    }

    fn quote(&mut self) -> Option<()> {
        self.literal("\"").or_else(|| self.literal("'"))
    }
}

fn matches(characters: &[&str], index: usize, marker: &[&str]) -> bool {
    index + marker.len() <= characters.len() && text::seq_eq(&characters[index..index + marker.len()], marker)
}

/// 닫는 기호 위치를 찾는다. 내용이 비어 있으면 서식으로 보지 않는다.
fn find_closing(characters: &[&str], start: usize, marker: &[&str]) -> Option<usize> {
    let mut index = start;
    while index + marker.len() <= characters.len() {
        if matches(characters, index, marker) {
            return if index > start { Some(index) } else { None };
        }
        index += 1;
    }
    None
}

/// 같은 서식이 이어지는 구간은 하나로 합친다. 저장 결과가 안정되게 유지하기 위해서다.
fn merge_adjacent(spans: Vec<StyledSpan>) -> Vec<StyledSpan> {
    let mut merged: Vec<StyledSpan> = Vec::new();
    for span in spans.into_iter().filter(|s| !s.text.is_empty()) {
        match merged.last_mut() {
            Some(last) if last.has_same_format(&span) => last.text.push_str(&span.text),
            _ => merged.push(span),
        }
    }
    merged
}
