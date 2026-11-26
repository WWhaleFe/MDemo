//! 서식이 적용된 문서의 중간 표현 (Swift `StyledText.swift`).
//!
//! 에디터는 마크다운 기호를 숨기고 서식만 보여 주므로, 화면의 텍스트와 파일의 마크다운은 서로 다르다.
//! 이 타입이 둘 사이의 다리다. UI 타입에 기대지 않는 순수 값이다.

use crate::text::{self, chars};

/// 줄 단위 블록 서식.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum BlockStyle {
    Paragraph,
    Heading { level: i64 },
    Bullet { indent: i64 },
    Ordered { indent: i64, number: i64 },
    Checkbox { indent: i64, checked: bool },
    Quote,
    Divider,
    /// 코드 박스 (MD-10). 한 줄씩 이 서식을 달고, 저장할 때 ``` 울타리로 묶는다.
    CodeBlock,
    /// 표의 한 줄 (MD-14). 구분 줄은 화면에 두지 않고 저장할 때 만들어 넣는다.
    TableRow,
    /// 이미지 한 줄 (IMG-01).
    Image(MarkdownImage),
}

impl BlockStyle {
    /// 목록 들여쓰기 단계 (Tab/Shift+Tab, KEY-08).
    pub fn indent(&self) -> i64 {
        match self {
            BlockStyle::Bullet { indent } | BlockStyle::Ordered { indent, .. } | BlockStyle::Checkbox { indent, .. } => *indent,
            _ => 0,
        }
    }

    /// Tab으로 단계를 조절할 수 있는 종류인가. 코드 박스 안의 Tab은 코드의 일부다.
    pub fn allows_indent_change(&self) -> bool {
        matches!(self, BlockStyle::Bullet { .. } | BlockStyle::Ordered { .. } | BlockStyle::Checkbox { .. })
    }
}

/// 이미지 줄의 내용 (IMG-07, IMG-08). 본문에는 `![설명](attachments/파일명 =너비)` 한 줄만 적는다.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct MarkdownImage {
    pub alt: String,
    /// 메모 폴더 기준 상대 경로 (예: `attachments/a1b2c3d4.png`).
    pub path: String,
    pub width: Option<i64>,
}

impl MarkdownImage {
    pub fn new(alt: &str, path: &str, width: Option<i64>) -> Self {
        MarkdownImage { alt: sanitized_alt(alt), path: path.to_string(), width: width.map(|w| w.max(1)) }
    }

    /// 경로의 마지막 조각. 첨부 폴더 안의 파일 이름이다.
    pub fn file_name(&self) -> String {
        if is_local_attachment_path(&self.path) {
            text::drop_first(&self.path, ATTACHMENTS_PREFIX_COUNT).to_string()
        } else {
            String::new()
        }
    }

    /// 한 줄 마크다운. 대괄호와 줄바꿈은 문법을 깨므로 설명에서 뺀다.
    pub fn markdown(&self) -> String {
        let size = self.width.map(|w| format!(" ={w}")).unwrap_or_default();
        format!("![{}]({}{})", self.alt, self.path, size)
    }

    /// 줄 전체가 이미지 문법일 때만 읽는다. 글 사이에 낀 이미지 문법은 일반 글자로 둔다.
    ///
    /// Swift는 `^!\[([^\]]*)\]\(([^()\s]+)(?:\s+=(\d+))?\)$`(ICU)로 읽는다. 되돌아가기를 해도 결과가 하나뿐인
    /// 꼴이라 같은 규칙을 직접 따라간다(`\s`는 White_Space, `\d`는 Numeric_Type=Decimal).
    pub fn parse(line: &str) -> Option<MarkdownImage> {
        let trimmed = text::trim_ws(line);
        if !text::has_prefix(trimmed, "![") || !text::has_suffix(trimmed, ")") {
            return None;
        }
        let rest = trimmed.strip_prefix("![")?;
        let alt_end = rest.find(']')?;
        let alt = &rest[..alt_end];
        let after = rest[alt_end + 1..].strip_prefix('(')?;
        // 경로: 괄호와 공백이 아닌 글자가 한 개 이상
        let path_end = after.find(|c: char| c == '(' || c == ')' || text::is_regex_space(c)).unwrap_or(after.len());
        if path_end == 0 {
            return None;
        }
        let path = &after[..path_end];
        let tail = &after[path_end..];
        let width = if tail == ")" {
            None
        } else {
            let t = tail.trim_start_matches(text::is_regex_space);
            if t.len() == tail.len() {
                return None;
            }
            let t = t.strip_prefix('=')?;
            let digits_end = t.find(|c: char| !text::is_decimal(c)).unwrap_or(t.len());
            if digits_end == 0 || &t[digits_end..] != ")" {
                return None;
            }
            // ASCII가 아닌 십진 숫자나 범위를 넘는 값은 Swift `Int(...)`가 읽지 못해 이미지가 아니다.
            let value = text::parse_int(&t[..digits_end])?;
            if value <= 0 {
                return None;
            }
            Some(value)
        };
        if !is_local_attachment_path(path) {
            return None;
        }
        Some(MarkdownImage::new(alt, path, width))
    }

    /// 첨부 폴더 바로 아래의 파일 이름만 허용한다.
    pub fn is_valid_file_name(name: &str) -> bool {
        !name.is_empty()
            && !text::str_eq(name, ".")
            && !text::str_eq(name, "..")
            && !text::contains(name, "/")
            && !text::contains(name, "\\")
            && !text::contains(name, "\0")
    }
}

const ATTACHMENTS_PREFIX: &str = "attachments/";
const ATTACHMENTS_PREFIX_COUNT: usize = 12;

fn is_local_attachment_path(path: &str) -> bool {
    text::has_prefix(path, ATTACHMENTS_PREFIX) && MarkdownImage::is_valid_file_name(text::drop_first(path, ATTACHMENTS_PREFIX_COUNT))
}

fn sanitized_alt(alt: &str) -> String {
    chars(alt)
        .into_iter()
        .filter(|c| !text::ch_eq(c, "[") && !text::ch_eq(c, "]") && !text::is_newline(c))
        .collect()
}

/// 번호 목록의 단계별 표식 (MD-03). 숫자 → 영문 → 로마자, 그 뒤로는 되풀이한다.
/// 파일에는 표준 마크다운대로 늘 `1.` 꼴로 적는다 (DOC-01, DOC-04).
pub enum OrderedListMarker {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OrderedListStyle {
    Number,
    Letter,
    Roman,
}

impl OrderedListMarker {
    pub fn style(indent: i64) -> OrderedListStyle {
        match indent.max(0) % 3 {
            0 => OrderedListStyle::Number,
            1 => OrderedListStyle::Letter,
            _ => OrderedListStyle::Roman,
        }
    }

    /// 화면에 보일 표식. 점은 포함하고 뒤 공백은 포함하지 않는다.
    pub fn text(number: i64, indent: i64) -> String {
        let value = number.max(1);
        match Self::style(indent) {
            OrderedListStyle::Number => format!("{value}."),
            OrderedListStyle::Letter => format!("{}.", Self::letters(value)),
            OrderedListStyle::Roman => format!("{}.", Self::roman(value)),
        }
    }

    /// 1 → a, 26 → z, 27 → aa. 엑셀 열 이름과 같은 규칙이다.
    pub fn letters(number: i64) -> String {
        let mut remaining = number.max(1);
        let mut result = String::new();
        while remaining > 0 {
            let index = ((remaining - 1) % 26) as u8;
            result.insert(0, (97 + index) as char);
            remaining = (remaining - 1) / 26;
        }
        result
    }

    /// 1 → i, 4 → iv, 9 → ix.
    pub fn roman(number: i64) -> String {
        const TABLE: [(i64, &str); 13] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"),
            (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ];
        let mut remaining = number.max(1);
        let mut result = String::new();
        for (value, symbol) in TABLE {
            while remaining >= value {
                result.push_str(symbol);
                remaining -= value;
            }
        }
        result
    }
}

/// 글자 단위 서식. 여러 개가 겹칠 수 있다(비트 집합).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub struct InlineStyleTag(pub u32);

impl InlineStyleTag {
    pub const NONE: InlineStyleTag = InlineStyleTag(0);
    pub const BOLD: InlineStyleTag = InlineStyleTag(1 << 0);
    pub const ITALIC: InlineStyleTag = InlineStyleTag(1 << 1);
    pub const STRIKETHROUGH: InlineStyleTag = InlineStyleTag(1 << 2);
    pub const HIGHLIGHT: InlineStyleTag = InlineStyleTag(1 << 3);
    pub const CODE: InlineStyleTag = InlineStyleTag(1 << 4);

    /// Swift `OptionSet.contains`: 주어진 표식이 모두 들어 있어야 참이다.
    pub fn contains(self, other: InlineStyleTag) -> bool {
        self.0 & other.0 == other.0
    }

    pub fn union(self, other: InlineStyleTag) -> InlineStyleTag {
        InlineStyleTag(self.0 | other.0)
    }

    pub fn insert(&mut self, other: InlineStyleTag) {
        self.0 |= other.0;
    }
}

impl std::ops::BitOr for InlineStyleTag {
    type Output = InlineStyleTag;
    fn bitor(self, rhs: InlineStyleTag) -> InlineStyleTag {
        self.union(rhs)
    }
}

/// 같은 서식이 이어지는 구간.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct StyledSpan {
    pub text: String,
    pub styles: InlineStyleTag,
    /// 글자 색 ("#RRGGBB"). None이면 테마의 기본 글자색.
    pub text_color: Option<String>,
    /// 형광펜 색 ("#RRGGBB"). `styles`에 형광이 있을 때만 뜻이 있고, None이면 기본 노랑이다.
    pub highlight_color: Option<String>,
}

impl StyledSpan {
    pub fn new(text: &str, styles: InlineStyleTag, text_color: Option<&str>, highlight_color: Option<&str>) -> Self {
        StyledSpan {
            text: text.to_string(),
            styles,
            text_color: InlineColor::normalized(text_color),
            highlight_color: if styles.contains(InlineStyleTag::HIGHLIGHT) { InlineColor::normalized(highlight_color) } else { None },
        }
    }

    pub fn plain(text: &str) -> Self {
        Self::new(text, InlineStyleTag::NONE, None, None)
    }

    pub fn with_styles(text: &str, styles: InlineStyleTag) -> Self {
        Self::new(text, styles, None, None)
    }

    /// 글자를 뺀 서식만 같은지. 이어 붙일 수 있는 구간인지 가릴 때 쓴다.
    pub fn has_same_format(&self, other: &StyledSpan) -> bool {
        self.styles == other.styles && self.text_color == other.text_color && self.highlight_color == other.highlight_color
    }
}

/// 글자 색 · 형광펜 색 표기 ("#RRGGBB"). 표준 마크다운에는 색 문법이 없어 HTML 태그로 남긴다 (DOC-04 확장).
pub enum InlineColor {}

impl InlineColor {
    /// "#abc123" → "#ABC123". 형식이 틀리면 None.
    pub fn normalized(hex: Option<&str>) -> Option<String> {
        let trimmed = text::trim_ws(hex?);
        if trimmed.is_empty() {
            return None;
        }
        let value = if text::has_prefix(trimmed, "#") { trimmed.to_string() } else { format!("#{trimmed}") };
        let digits = chars(text::drop_first(&value, 1));
        if digits.len() != 6 || !digits.iter().all(|d| text::is_hex_digit(d)) {
            return None;
        }
        Some(text::uppercased(&value))
    }

    pub(crate) fn text_opening(hex: &str) -> String {
        format!("<span style=\"color:{hex}\">")
    }
    pub(crate) const TEXT_CLOSING: &'static str = "</span>";

    /// 기본 노랑은 `==`로 쓰고, 다른 색일 때만 이 태그를 쓴다.
    pub(crate) fn highlight_opening(hex: &str) -> String {
        format!("<mark style=\"background:{hex}\">")
    }
    pub(crate) const HIGHLIGHT_CLOSING: &'static str = "</mark>";
}

/// 한 줄.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct StyledLine {
    pub block: BlockStyle,
    pub spans: Vec<StyledSpan>,
}

impl StyledLine {
    pub fn new(block: BlockStyle, spans: Vec<StyledSpan>) -> Self {
        StyledLine { block, spans }
    }

    /// 글자 하나짜리 구간으로 만든다. 글자가 비면 구간이 없다.
    pub fn with_text(block: BlockStyle, text: &str) -> Self {
        StyledLine { block, spans: if text.is_empty() { vec![] } else { vec![StyledSpan::plain(text)] } }
    }

    /// 서식을 뺀 순수 텍스트 (화면에 보이는 내용).
    pub fn plain_text(&self) -> String {
        self.spans.iter().map(|s| s.text.as_str()).collect()
    }
}
