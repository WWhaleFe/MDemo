//! 서식이 적용된 문서를 표준 마크다운 문자열로 되돌린다 (Swift `MarkdownSerializer.swift`, DOC-01, CHK-05).
//!
//! 화면에서는 기호를 숨기지만 파일에는 반드시 기호가 살아 있어야 한다.

use crate::parser::CODE_FENCE;
use crate::styled::*;
use crate::table;

/// 어디에 쓸 마크다운인가.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Flavor {
    /// 메모 파일. 이 앱의 확장(==형광==, 색 태그)을 모두 남긴다.
    File,
    /// 클립보드 - 노션 등 다른 앱에 붙여 넣을 글. 색 태그와 ==형광==은 빼고 글자만 남기며,
    /// 목록 들여쓰기는 4칸으로 한다(표준 마크다운에서 번호 목록 아래 단계는 3칸 이상이어야 인식된다).
    Clipboard,
}

impl Flavor {
    fn indent_unit(self) -> &'static str {
        if self == Flavor::File { "  " } else { "    " }
    }

    fn keeps_app_extensions(self) -> bool {
        self == Flavor::File
    }
}

pub fn serialize(lines: &[StyledLine], flavor: Flavor) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut inside_code_block = false;
    let mut inside_table = false;

    for line in lines {
        // 클립보드로 나가는 글에서 이미지 줄은 뺀다. 로컬 경로는 받는 앱이 읽을 수 없다 (IMG-01).
        if flavor == Flavor::Clipboard && matches!(line.block, BlockStyle::Image(_)) {
            continue;
        }

        let is_code = line.block == BlockStyle::CodeBlock;
        // 코드 박스는 줄마다 기호를 붙이는 대신, 시작과 끝에 울타리를 한 번씩 친다 (MD-10).
        if is_code != inside_code_block {
            out.push(CODE_FENCE.to_string());
            inside_code_block = is_code;
        }

        let text = serialize_line(line, flavor);
        // 표는 첫 줄 뒤에 구분 줄이 있어야 표로 읽힌다. 화면에 없던 것을 여기서 되살린다 (MD-14).
        let is_table = line.block == BlockStyle::TableRow;
        let columns = if is_table && !inside_table { Some(table::column_count_of(&text)) } else { None };
        out.push(text);
        if let Some(columns) = columns {
            out.push(table::separator_row(columns));
        }
        inside_table = is_table;
    }
    if inside_code_block {
        out.push(CODE_FENCE.to_string());
    }
    out.join("\n")
}

pub fn serialize_line(line: &StyledLine, flavor: Flavor) -> String {
    // 코드는 있는 그대로 적는다. 기호를 붙이면 코드가 아니게 된다.
    if line.block == BlockStyle::CodeBlock {
        return line.plain_text();
    }
    if let BlockStyle::Image(image) = &line.block {
        return image.markdown();
    }
    let content: String = line.spans.iter().map(|s| serialize_span(s, flavor)).collect();
    block_prefix(&line.block, flavor) + &content
}

fn block_prefix(block: &BlockStyle, flavor: Flavor) -> String {
    match block {
        BlockStyle::Paragraph => String::new(),
        BlockStyle::Heading { level } => "#".repeat((*level).clamp(1, 6) as usize) + " ",
        BlockStyle::Bullet { indent } => indentation(*indent, flavor) + "- ",
        BlockStyle::Ordered { indent, number } => format!("{}{number}. ", indentation(*indent, flavor)),
        BlockStyle::Checkbox { indent, checked } => indentation(*indent, flavor) + if *checked { "- [x] " } else { "- [ ] " },
        BlockStyle::Quote => "> ".to_string(),
        BlockStyle::Divider => "---".to_string(),
        // 울타리는 serialize가 붙인다. 줄 자체에는 앞머리가 없다.
        BlockStyle::CodeBlock => String::new(),
        // 세로줄은 내용에 이미 들어 있다.
        BlockStyle::TableRow => String::new(),
        // 줄 전체가 이미지 문법이라 serialize_line이 따로 만든다.
        BlockStyle::Image(_) => String::new(),
    }
}

/// 들여쓰기 한 단계는 공백 2칸. 탭을 쓰지 않는 이유는 다른 도구에서 폭이 달라 보이기 때문이다.
fn indentation(level: i64, flavor: Flavor) -> String {
    flavor.indent_unit().repeat(level.max(0) as usize)
}

/// 겹친 서식은 항상 같은 순서로 감싼다. 순서가 흔들리면 저장할 때마다 파일이 달라져
/// 동기화가 불필요한 충돌을 만든다 (SYNC-06).
fn serialize_span(span: &StyledSpan, flavor: Flavor) -> String {
    let mut text = span.text.clone();
    if text.is_empty() {
        return text;
    }
    // 코드가 가장 안쪽 - 마크다운에서 코드 구간 안의 기호는 서식으로 해석되지 않는다.
    if span.styles.contains(InlineStyleTag::CODE) {
        text = format!("`{text}`");
    }
    if span.styles.contains(InlineStyleTag::HIGHLIGHT) && flavor.keeps_app_extensions() {
        // 기본 노랑은 예전처럼 `==`로 둔다. 이미 저장된 파일이 바뀌지 않게 하기 위해서다.
        text = match &span.highlight_color {
            Some(hex) => InlineColor::highlight_opening(hex) + &text + InlineColor::HIGHLIGHT_CLOSING,
            None => format!("=={text}=="),
        };
    }
    if span.styles.contains(InlineStyleTag::STRIKETHROUGH) {
        text = format!("~~{text}~~");
    }
    if span.styles.contains(InlineStyleTag::ITALIC) {
        text = format!("*{text}*");
    }
    if span.styles.contains(InlineStyleTag::BOLD) {
        text = format!("**{text}**");
    }
    // 글자 색이 가장 바깥이다.
    if let Some(hex) = &span.text_color {
        if flavor.keeps_app_extensions() {
            text = InlineColor::text_opening(hex) + &text + InlineColor::TEXT_CLOSING;
        }
    }
    text
}
