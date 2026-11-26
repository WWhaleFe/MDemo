//! 입력 중 자동 서식 변환 규칙 (Swift `InputRule.swift` + `Rules/BlockRules.swift` + `Rules/InlineRules.swift`, MD-01 ~ MD-13).
//!
//! 위치는 모두 `Character`(확장 문자소) 단위다. UTF-16 오프셋이 아니다.
//! 새 마크다운 문법을 추가할 때는 `InputRule`을 채택한 타입을 하나 만들어 `InputRuleSet`에 등록한다.

use crate::styled::{BlockStyle, InlineStyleTag};
use crate::text::{self, chars};
use std::ops::Range;

/// 규칙이 판단에 쓰는 정보. `content`는 화면 표식을 뺀 순수 내용이고, `block`은 그 줄에 이미 걸린 블록 서식이다.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputRuleContext {
    pub content: String,
    /// `content` 기준 커서 위치 (Character 단위).
    pub caret_offset: usize,
    pub block: BlockStyle,
}

impl InputRuleContext {
    pub fn new(content: &str, caret_offset: usize, block: BlockStyle) -> Self {
        InputRuleContext { content: content.to_string(), caret_offset, block }
    }

    pub fn paragraph(content: &str, caret_offset: usize) -> Self {
        Self::new(content, caret_offset, BlockStyle::Paragraph)
    }
}

/// 변환 결과.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InputRuleOutcome {
    /// 줄 전체를 이 블록 서식으로 바꾼다.
    Block(BlockStyle),
    /// 기호를 지운 자리의 글자에 이 서식을 입힌다.
    Inline(InlineStyleTag),
}

/// 에디터가 실제 텍스트에 반영할 변경 내용.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputRuleMatch {
    /// `content`에서 지울 구간 (Character 단위).
    pub range: Range<usize>,
    /// 그 자리에 넣을 문자열. 기호를 숨기는 경우 빈 문자열이 된다.
    pub replacement: String,
    pub outcome: InputRuleOutcome,
}

pub trait InputRule: Send + Sync {
    /// 스펙 ID를 그대로 사용한다 (예: "MD-01").
    fn id(&self) -> &str;
    /// 변환이 필요하면 결과를 돌려주고, 아니면 None.
    fn matches(&self, context: &InputRuleContext) -> Option<InputRuleMatch>;
}

/// 규칙 모음. 등록 순서대로 검사한다.
#[derive(Default)]
pub struct InputRuleSet {
    rules: Vec<Box<dyn InputRule>>,
}

impl InputRuleSet {
    pub fn new(rules: Vec<Box<dyn InputRule>>) -> Self {
        InputRuleSet { rules }
    }

    pub fn register(&mut self, rule: Box<dyn InputRule>) {
        self.rules.push(rule);
    }

    pub fn rules(&self) -> &[Box<dyn InputRule>] {
        &self.rules
    }

    pub fn first_match(&self, context: &InputRuleContext) -> Option<InputRuleMatch> {
        self.rules.iter().find_map(|rule| rule.matches(context))
    }

    /// 편의용 - 문단 상태의 줄을 검사한다.
    pub fn first_match_line(&self, line: &str, caret_offset: usize) -> Option<InputRuleMatch> {
        self.first_match(&InputRuleContext::paragraph(line, caret_offset))
    }

    /// M1에서 지원하는 규칙 모음. 등록 순서가 곧 우선순위다.
    /// - 코드 박스가 인라인 코드(`)보다 먼저다 - ```는 `로도 읽힌다.
    /// - 체크박스가 글머리 목록보다 먼저다: `- [ ]`는 `- `로도 읽히기 때문이다.
    /// - 굵게(`**`)가 기울임(`*`)보다 먼저다.
    pub fn m1() -> InputRuleSet {
        InputRuleSet::new(vec![
            Box::new(CodeBlockRule),
            Box::new(HeadingRule),
            Box::new(CheckboxRule),
            Box::new(BulletListRule),
            Box::new(OrderedListRule),
            Box::new(PairedDelimiterRule::bold()),
            Box::new(PairedDelimiterRule::strikethrough()),
            Box::new(PairedDelimiterRule::highlight()),
            Box::new(PairedDelimiterRule::inline_code()),
            Box::new(PairedDelimiterRule::italic()),
        ])
    }
}

fn block_match(range: Range<usize>, block: BlockStyle) -> InputRuleMatch {
    InputRuleMatch { range, replacement: String::new(), outcome: InputRuleOutcome::Block(block) }
}

/// 앞쪽 공백을 세어 들여쓰기 단계를 구한다. 공백 2칸 또는 탭 1개가 한 단계다.
fn indent_level_of(content: &str) -> (i64, usize) {
    let mut spaces = 0i64;
    let mut consumed = 0usize;
    for g in chars(content) {
        if text::ch_eq(g, " ") {
            spaces += 1;
            consumed += 1;
        } else if text::ch_eq(g, "\t") {
            spaces += 2;
            consumed += 1;
        } else {
            break;
        }
    }
    (spaces / 2, consumed)
}

/// `# ` ~ `###### ` → 제목 1~6 (MD-01)
pub struct HeadingRule;

impl InputRule for HeadingRule {
    fn id(&self) -> &str {
        "MD-01"
    }

    fn matches(&self, context: &InputRuleContext) -> Option<InputRuleMatch> {
        if context.block != BlockStyle::Paragraph {
            return None;
        }
        let cs = chars(&context.content);
        let mut level = 0usize;
        while level < cs.len() && text::ch_eq(cs[level], "#") && level < 6 {
            level += 1;
        }
        if !(level > 0 && level < cs.len() && text::ch_eq(cs[level], " ")) {
            return None;
        }
        let marker_length = level + 1;
        // 커서가 기호 바로 뒤에 있을 때만 변환한다. 이미 쓴 줄을 건드리지 않기 위해서다.
        if context.caret_offset != marker_length {
            return None;
        }
        Some(block_match(0..marker_length, BlockStyle::Heading { level: level as i64 }))
    }
}

/// `- ` 또는 `* ` → 글머리 기호 목록 (MD-02)
pub struct BulletListRule;

impl InputRule for BulletListRule {
    fn id(&self) -> &str {
        "MD-02"
    }

    fn matches(&self, context: &InputRuleContext) -> Option<InputRuleMatch> {
        if context.block != BlockStyle::Paragraph {
            return None;
        }
        let (level, content_start) = indent_level_of(&context.content);
        let rest = text::drop_first(&context.content, content_start);
        if !(text::has_prefix(rest, "- ") || text::has_prefix(rest, "* ")) {
            return None;
        }
        // 체크박스는 별도 규칙이 처리한다.
        if text::has_prefix(rest, "- [") {
            return None;
        }
        let upper = content_start + 2;
        if context.caret_offset != upper {
            return None;
        }
        Some(block_match(content_start..upper, BlockStyle::Bullet { indent: level }))
    }
}

/// `1. ` → 번호 목록 (MD-03)
pub struct OrderedListRule;

impl InputRule for OrderedListRule {
    fn id(&self) -> &str {
        "MD-03"
    }

    fn matches(&self, context: &InputRuleContext) -> Option<InputRuleMatch> {
        if context.block != BlockStyle::Paragraph {
            return None;
        }
        let (level, content_start) = indent_level_of(&context.content);
        let rest = chars(text::drop_first(&context.content, content_start));
        let digits = rest.iter().take_while(|c| text::is_number(c)).count();
        if !(digits > 0 && digits + 1 < rest.len() && text::ch_eq(rest[digits], ".") && text::ch_eq(rest[digits + 1], " ")) {
            return None;
        }
        let number = text::parse_int(&rest[..digits].concat())?;
        let upper = content_start + digits + 2;
        if context.caret_offset != upper {
            return None;
        }
        Some(block_match(content_start..upper, BlockStyle::Ordered { indent: level, number }))
    }
}

/// ``` ` ``` 세 개 → 코드 박스 (MD-10). 공백까지 친 경우를 받는다.
pub struct CodeBlockRule;

impl InputRule for CodeBlockRule {
    fn id(&self) -> &str {
        "MD-10"
    }

    fn matches(&self, context: &InputRuleContext) -> Option<InputRuleMatch> {
        if context.block != BlockStyle::Paragraph {
            return None;
        }
        const MARKER: &str = "``` ";
        if !text::has_prefix(&context.content, MARKER) || context.caret_offset != 4 {
            return None;
        }
        Some(block_match(0..4, BlockStyle::CodeBlock))
    }
}

/// 체크박스 (MD-04). 저장 시 표준 문법을 유지한다 (CHK-05).
///
/// 두 갈래로 들어올 수 있다:
/// 1. 문단에서 `- [ ] `를 통째로 입력
/// 2. 이미 글머리 목록인 줄에서 `[ ] `만 입력 - 실제 사용에서는 이쪽이 훨씬 흔하다
pub struct CheckboxRule;

/// `[]`처럼 공백을 생략한 형태도 받아준다.
const UNCHECKED_MARKERS: [&str; 2] = ["[ ] ", "[] "];
const CHECKED_MARKERS: [&str; 2] = ["[x] ", "[X] "];

impl InputRule for CheckboxRule {
    fn id(&self) -> &str {
        "MD-04"
    }

    fn matches(&self, context: &InputRuleContext) -> Option<InputRuleMatch> {
        match &context.block {
            BlockStyle::Paragraph => self.match_from_paragraph(context),
            BlockStyle::Bullet { indent } => self.match_from_bullet(context, *indent),
            _ => None,
        }
    }
}

impl CheckboxRule {
    /// 문단에서 들어오는 두 형태를 모두 받는다. `- [ ] `(표준)와 `[ ] `(대괄호만).
    fn match_from_paragraph(&self, context: &InputRuleContext) -> Option<InputRuleMatch> {
        let (level, content_start) = indent_level_of(&context.content);
        let rest = text::drop_first(&context.content, content_start);

        let expand = |markers: &[&str]| -> Vec<String> { markers.iter().flat_map(|m| [m.to_string(), format!("- {m}")]).collect() };
        for (markers, checked) in [(expand(&UNCHECKED_MARKERS), false), (expand(&CHECKED_MARKERS), true)] {
            for marker in &markers {
                if text::has_prefix(rest, marker) {
                    let upper = content_start + text::count(marker);
                    if context.caret_offset != upper {
                        return None;
                    }
                    return Some(block_match(content_start..upper, BlockStyle::Checkbox { indent: level, checked }));
                }
            }
        }
        None
    }

    /// 이미 글머리 목록인 줄에서 `[ ] `를 치면 체크박스로 바뀐다.
    fn match_from_bullet(&self, context: &InputRuleContext, indent: i64) -> Option<InputRuleMatch> {
        for (markers, checked) in [(&UNCHECKED_MARKERS, false), (&CHECKED_MARKERS, true)] {
            for marker in markers {
                if text::has_prefix(&context.content, marker) {
                    let upper = text::count(marker);
                    if context.caret_offset != upper {
                        return None;
                    }
                    return Some(block_match(0..upper, BlockStyle::Checkbox { indent, checked }));
                }
            }
        }
        None
    }
}

/// 짝을 이루는 기호로 감싼 구간에 서식을 입히는 규칙들 (MD-05 ~ MD-09).
/// 닫는 기호를 입력하는 순간 변환된다. 여는 기호까지 되짚어 찾는다.
pub struct PairedDelimiterRule {
    id: &'static str,
    delimiter: &'static str,
    style: InlineStyleTag,
}

impl PairedDelimiterRule {
    pub fn new(id: &'static str, delimiter: &'static str, style: InlineStyleTag) -> Self {
        PairedDelimiterRule { id, delimiter, style }
    }

    /// `**텍스트**` → 굵게 (MD-05)
    pub fn bold() -> Self {
        Self::new("MD-05", "**", InlineStyleTag::BOLD)
    }

    /// `*텍스트*` → 기울임 (MD-06). 굵게 규칙보다 뒤에 등록해야 `**`가 먼저 잡힌다.
    pub fn italic() -> Self {
        Self::new("MD-06", "*", InlineStyleTag::ITALIC)
    }

    /// `~~텍스트~~` → 취소선 (MD-07)
    pub fn strikethrough() -> Self {
        Self::new("MD-07", "~~", InlineStyleTag::STRIKETHROUGH)
    }

    /// `==텍스트==` → 형광색 (MD-08)
    pub fn highlight() -> Self {
        Self::new("MD-08", "==", InlineStyleTag::HIGHLIGHT)
    }

    /// `` `텍스트` `` → 인라인 코드 (MD-09)
    pub fn inline_code() -> Self {
        Self::new("MD-09", "`", InlineStyleTag::CODE)
    }
}

impl InputRule for PairedDelimiterRule {
    fn id(&self) -> &str {
        self.id
    }

    fn matches(&self, context: &InputRuleContext) -> Option<InputRuleMatch> {
        let characters = chars(&context.content);
        let delimiter = chars(self.delimiter);
        let length = delimiter.len();
        let caret = context.caret_offset;

        // 커서 바로 앞이 닫는 기호여야 한다.
        if !(caret >= length * 2 + 1 && caret <= characters.len()) {
            return None;
        }
        let closing_start = caret - length;
        if !text::seq_eq(&characters[closing_start..caret], &delimiter) {
            return None;
        }

        // 여는 기호를 뒤에서부터 찾는다.
        let mut opening_start = closing_start as i64 - length as i64;
        while opening_start >= 0 {
            let start = opening_start as usize;
            if text::seq_eq(&characters[start..start + length], &delimiter) {
                let content_range = start + length..closing_start;
                if content_range.is_empty() {
                    return None;
                }
                let inner = characters[content_range].concat();
                // 기호만 있고 내용이 공백뿐이면 사용자가 아직 입력 중이다.
                if text::trim_ws(&inner).is_empty() {
                    return None;
                }
                return Some(InputRuleMatch { range: start..caret, replacement: inner, outcome: InputRuleOutcome::Inline(self.style) });
            }
            opening_start -= 1;
        }
        None
    }
}
