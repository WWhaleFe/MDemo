//! 마크다운 경계. 위치는 확장 문자소 단위이며 UI와 파일 시스템에 의존하지 않는다.
use mdemo_markdown as md;
#[derive(uniffi::Enum)]
pub enum MdBlock {
    Paragraph,
    Heading { level: i64 },
    Bullet { indent: i64 },
    Ordered { indent: i64, number: i64 },
    Checkbox { indent: i64, checked: bool },
    Quote,
    Divider,
    CodeBlock,
    TableRow,
    Image { image: MdMarkdownImage },
}
impl From<MdBlock> for md::BlockStyle {
    fn from(value: MdBlock) -> Self {
        match value {
            MdBlock::Paragraph => md::BlockStyle::Paragraph,
            MdBlock::Heading { level } => md::BlockStyle::Heading { level },
            MdBlock::Bullet { indent } => md::BlockStyle::Bullet { indent },
            MdBlock::Ordered { indent, number } => md::BlockStyle::Ordered { indent, number },
            MdBlock::Checkbox { indent, checked } => md::BlockStyle::Checkbox { indent, checked },
            MdBlock::Quote => md::BlockStyle::Quote,
            MdBlock::Divider => md::BlockStyle::Divider,
            MdBlock::CodeBlock => md::BlockStyle::CodeBlock,
            MdBlock::TableRow => md::BlockStyle::TableRow,
            MdBlock::Image { image } => md::BlockStyle::Image(image.into()),
        }
    }
}
impl From<md::BlockStyle> for MdBlock {
    fn from(value: md::BlockStyle) -> Self {
        match value {
            md::BlockStyle::Paragraph => MdBlock::Paragraph,
            md::BlockStyle::Heading { level } => MdBlock::Heading { level },
            md::BlockStyle::Bullet { indent } => MdBlock::Bullet { indent },
            md::BlockStyle::Ordered { indent, number } => MdBlock::Ordered { indent, number },
            md::BlockStyle::Checkbox { indent, checked } => MdBlock::Checkbox { indent, checked },
            md::BlockStyle::Quote => MdBlock::Quote,
            md::BlockStyle::Divider => MdBlock::Divider,
            md::BlockStyle::CodeBlock => MdBlock::CodeBlock,
            md::BlockStyle::TableRow => MdBlock::TableRow,
            md::BlockStyle::Image(image) => MdBlock::Image {
                image: image.into(),
            },
        }
    }
}
#[derive(uniffi::Record)]
pub struct MdMarkdownImage {
    pub alt: String,
    pub path: String,
    pub width: Option<i64>,
}
impl From<MdMarkdownImage> for md::MarkdownImage {
    fn from(v: MdMarkdownImage) -> Self {
        Self {
            alt: v.alt,
            path: v.path,
            width: v.width,
        }
    }
}
impl From<md::MarkdownImage> for MdMarkdownImage {
    fn from(v: md::MarkdownImage) -> Self {
        Self {
            alt: v.alt,
            path: v.path,
            width: v.width,
        }
    }
}
#[derive(uniffi::Record)]
pub struct MdStyledSpan {
    pub text: String,
    pub styles: u64,
    pub text_color: Option<String>,
    pub highlight_color: Option<String>,
}
impl From<MdStyledSpan> for md::StyledSpan {
    fn from(v: MdStyledSpan) -> Self {
        Self {
            text: v.text,
            styles: md::InlineStyleTag(v.styles),
            text_color: v.text_color,
            highlight_color: v.highlight_color,
        }
    }
}
impl From<md::StyledSpan> for MdStyledSpan {
    fn from(v: md::StyledSpan) -> Self {
        Self {
            text: v.text,
            styles: v.styles.0,
            text_color: v.text_color,
            highlight_color: v.highlight_color,
        }
    }
}
#[derive(uniffi::Record)]
pub struct MdStyledLine {
    pub block: MdBlock,
    pub spans: Vec<MdStyledSpan>,
}
impl From<MdStyledLine> for md::StyledLine {
    fn from(v: MdStyledLine) -> Self {
        Self {
            block: v.block.into(),
            spans: v.spans.into_iter().map(Into::into).collect(),
        }
    }
}
impl From<md::StyledLine> for MdStyledLine {
    fn from(v: md::StyledLine) -> Self {
        Self {
            block: v.block.into(),
            spans: v.spans.into_iter().map(Into::into).collect(),
        }
    }
}
#[derive(uniffi::Record)]
pub struct MdSlashCommand {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub keywords: Vec<String>,
    pub shortcut: String,
    pub block: MdBlock,
}
impl From<MdSlashCommand> for md::slash::SlashCommand {
    fn from(v: MdSlashCommand) -> Self {
        Self {
            id: v.id,
            title: v.title,
            subtitle: v.subtitle,
            keywords: v.keywords,
            shortcut: v.shortcut,
            block: v.block.into(),
        }
    }
}
impl From<md::slash::SlashCommand> for MdSlashCommand {
    fn from(v: md::slash::SlashCommand) -> Self {
        Self {
            id: v.id,
            title: v.title,
            subtitle: v.subtitle,
            keywords: v.keywords,
            shortcut: v.shortcut,
            block: v.block.into(),
        }
    }
}
#[derive(uniffi::Record)]
pub struct MdOcrLine {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub confidence: f64,
}
impl From<MdOcrLine> for md::ocr::OcrLine {
    fn from(v: MdOcrLine) -> Self {
        Self {
            text: v.text,
            x: v.x,
            y: v.y,
            width: v.width,
            height: v.height,
            confidence: v.confidence,
        }
    }
}
impl From<md::ocr::OcrLine> for MdOcrLine {
    fn from(v: md::ocr::OcrLine) -> Self {
        Self {
            text: v.text,
            x: v.x,
            y: v.y,
            width: v.width,
            height: v.height,
            confidence: v.confidence,
        }
    }
}

#[derive(uniffi::Enum)]
pub enum MdFlavor {
    File,
    Clipboard,
}
impl From<MdFlavor> for md::Flavor {
    fn from(v: MdFlavor) -> Self {
        match v {
            MdFlavor::File => Self::File,
            MdFlavor::Clipboard => Self::Clipboard,
        }
    }
}
#[derive(uniffi::Enum)]
pub enum MdOrderedStyle {
    Number,
    Letter,
    Roman,
}
#[derive(uniffi::Record)]
pub struct MdRuleMatch {
    pub start: u64,
    pub end: u64,
    pub replacement: String,
    pub outcome: MdRuleOutcome,
}
#[derive(uniffi::Enum)]
pub enum MdRuleOutcome {
    Block { block: MdBlock },
    Inline { styles: u64 },
}
#[derive(uniffi::Enum)]
pub enum MdRule {
    CodeBlock,
    Heading,
    Checkbox,
    Bullet,
    Ordered,
    Paired { delimiter: String, styles: u64 },
}
#[uniffi::export]
pub fn markdown_first_match(
    content: String,
    caret: i64,
    block: MdBlock,
    rules: Vec<MdRule>,
) -> Option<MdRuleMatch> {
    use md::input_rule::*;
    if caret < 0 {
        return None;
    }
    let context = InputRuleContext::new(&content, caret as usize, block.into());
    let rules = InputRuleSet::new(
        rules
            .into_iter()
            .map(|r| -> Box<dyn InputRule> {
                match r {
                    MdRule::CodeBlock => Box::new(CodeBlockRule),
                    MdRule::Heading => Box::new(HeadingRule),
                    MdRule::Checkbox => Box::new(CheckboxRule),
                    MdRule::Bullet => Box::new(BulletListRule),
                    MdRule::Ordered => Box::new(OrderedListRule),
                    MdRule::Paired { delimiter, styles } => Box::new(PairedDelimiterRule::new(
                        "",
                        &delimiter,
                        md::InlineStyleTag(styles),
                    )),
                }
            })
            .collect(),
    );
    let m = rules.first_match(&context)?;
    Some(MdRuleMatch {
        start: m.range.start as u64,
        end: m.range.end as u64,
        replacement: m.replacement,
        outcome: match m.outcome {
            InputRuleOutcome::Block(b) => MdRuleOutcome::Block { block: b.into() },
            InputRuleOutcome::Inline(s) => MdRuleOutcome::Inline { styles: s.0 },
        },
    })
}
#[uniffi::export]
pub fn markdown_parse(text: String) -> Vec<MdStyledLine> {
    md::parser::parse(&text)
        .into_iter()
        .map(Into::into)
        .collect()
}
#[uniffi::export]
pub fn markdown_parse_line(text: String) -> MdStyledLine {
    md::parser::parse_line(&text).into()
}
#[uniffi::export]
pub fn markdown_parse_inline(text: String) -> Vec<MdStyledSpan> {
    md::parser::parse_inline(&text)
        .into_iter()
        .map(Into::into)
        .collect()
}
#[uniffi::export]
pub fn markdown_serialize(lines: Vec<MdStyledLine>, flavor: MdFlavor) -> String {
    md::serializer::serialize(
        &lines.into_iter().map(Into::into).collect::<Vec<_>>(),
        flavor.into(),
    )
}
#[uniffi::export]
pub fn markdown_serialize_line(line: MdStyledLine, flavor: MdFlavor) -> String {
    md::serializer::serialize_line(&line.into(), flavor.into())
}
#[uniffi::export]
pub fn markdown_table_is_row(line: String) -> bool {
    md::table::is_row(&line)
}
#[uniffi::export]
pub fn markdown_table_is_separator_row(line: String) -> bool {
    md::table::is_separator_row(&line)
}
#[uniffi::export]
pub fn markdown_table_cells(line: String) -> Vec<String> {
    md::table::cells_of(&line)
}
#[uniffi::export]
pub fn markdown_table_column_count(line: String) -> u64 {
    md::table::column_count_of(&line) as u64
}
#[uniffi::export]
pub fn markdown_table_is_empty_row(line: String) -> bool {
    md::table::is_empty_row(&line)
}
#[uniffi::export]
pub fn markdown_separator_row(columns: i64) -> String {
    md::table::separator_row(columns.max(1) as usize)
}
#[uniffi::export]
pub fn markdown_empty_row(columns: i64) -> String {
    md::table::empty_row(columns.max(1) as usize)
}
#[uniffi::export]
pub fn markdown_row(cells: Vec<String>) -> String {
    md::table::row(&cells)
}
#[uniffi::export]
pub fn markdown_skeleton(columns: i64, rows: i64) -> Vec<String> {
    md::table::skeleton(columns.max(1) as usize, rows.max(2) as usize)
}
#[uniffi::export]
pub fn markdown_pasted_normalize(text: String) -> String {
    md::pasted::normalize(&text)
}
#[uniffi::export]
pub fn markdown_pasted_parse(text: String) -> Vec<MdStyledLine> {
    md::pasted::parse(&text)
        .into_iter()
        .map(Into::into)
        .collect()
}
#[uniffi::export]
pub fn markdown_ocr_build(lines: Vec<MdOcrLine>, plain: bool) -> String {
    md::ocr::build(
        &lines.into_iter().map(Into::into).collect::<Vec<_>>(),
        if plain {
            md::ocr::OcrMode::Plain
        } else {
            md::ocr::OcrMode::Markdown
        },
    )
}
#[uniffi::export]
pub fn markdown_image_sanitized(text: String) -> String {
    md::image_name::sanitized(&text)
}
#[uniffi::export]
pub fn markdown_image_default_name(
    alt: String,
    title: Option<String>,
    ordinal: i64,
    extension: String,
) -> String {
    md::image_name::default_name(&alt, title.as_deref(), ordinal, &extension)
}
#[uniffi::export]
pub fn markdown_slash_filter(query: String, commands: Vec<MdSlashCommand>) -> Vec<MdSlashCommand> {
    md::slash::filter(
        &query,
        &commands.into_iter().map(Into::into).collect::<Vec<_>>(),
    )
    .into_iter()
    .map(Into::into)
    .collect()
}

#[uniffi::export]
pub fn markdown_image_parse(line: String) -> Option<MdMarkdownImage> {
    md::MarkdownImage::parse(&line).map(Into::into)
}
#[uniffi::export]
pub fn markdown_image_valid_name(name: String) -> bool {
    md::MarkdownImage::is_valid_file_name(&name)
}
#[uniffi::export]
pub fn markdown_image_markup(image: MdMarkdownImage) -> String {
    md::MarkdownImage::from(image).markdown()
}
#[uniffi::export]
pub fn markdown_image_file_name(image: MdMarkdownImage) -> String {
    md::MarkdownImage::from(image).file_name()
}
#[uniffi::export]
pub fn markdown_color(hex: Option<String>) -> Option<String> {
    md::InlineColor::normalized(hex.as_deref())
}
#[uniffi::export]
pub fn markdown_ordered_style(indent: i64) -> MdOrderedStyle {
    match md::OrderedListMarker::style(indent) {
        md::styled::OrderedListStyle::Number => MdOrderedStyle::Number,
        md::styled::OrderedListStyle::Letter => MdOrderedStyle::Letter,
        md::styled::OrderedListStyle::Roman => MdOrderedStyle::Roman,
    }
}
#[uniffi::export]
pub fn markdown_ordered_text(number: i64, indent: i64) -> String {
    md::OrderedListMarker::text(number, indent)
}
#[uniffi::export]
pub fn markdown_ordered_letters(number: i64) -> String {
    md::OrderedListMarker::letters(number)
}
#[uniffi::export]
pub fn markdown_ordered_roman(number: i64) -> String {
    md::OrderedListMarker::roman(number)
}
#[uniffi::export]
pub fn markdown_slash_standard() -> Vec<MdSlashCommand> {
    md::slash::standard().into_iter().map(Into::into).collect()
}

/// 슬래시 팝업의 인라인 서식 안내도 엔진의 같은 목록을 사용한다.
#[derive(uniffi::Record)]
pub struct MdInlineHint {
    pub label: String,
    pub shortcut: String,
}
#[uniffi::export]
pub fn markdown_slash_inline_hints() -> Vec<MdInlineHint> {
    md::slash::INLINE_HINTS
        .iter()
        .map(|(label, shortcut)| MdInlineHint {
            label: label.to_string(),
            shortcut: shortcut.to_string(),
        })
        .collect()
}
