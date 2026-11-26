//! 슬래시 명령 (Swift `SlashCommand.swift`, SL-01 ~ SL-05).
//!
//! 줄 시작에서 `/`를 치면 목록이 뜨고, 이어 입력하면 좁혀지고, 고르면 그 블록으로 바뀐다.
//! 팝업을 그리는 일은 화면 쪽이 하고, 여기서는 무엇이 있고 무엇이 걸리는지만 정한다.

use crate::styled::BlockStyle;
use crate::text::{self, chars};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SlashCommand {
    pub id: String,
    /// 메뉴에 보이는 이름.
    pub title: String,
    /// 무엇을 하는지 한 줄 설명.
    pub subtitle: String,
    /// 검색어. 한글과 영어를 모두 넣어 어느 쪽으로 쳐도 걸리게 한다 (SL-05).
    pub keywords: Vec<String>,
    /// 같은 결과를 내는 마크다운 입력. 목록에 함께 보여 주면 자연스럽게 익히게 된다.
    pub shortcut: String,
    /// 고르면 적용될 블록.
    pub block: BlockStyle,
}

fn command(id: &str, title: &str, subtitle: &str, keywords: &[&str], shortcut: &str, block: BlockStyle) -> SlashCommand {
    SlashCommand {
        id: id.to_string(),
        title: title.to_string(),
        subtitle: subtitle.to_string(),
        keywords: keywords.iter().map(|k| k.to_string()).collect(),
        shortcut: shortcut.to_string(),
        block,
    }
}

/// 기본 명령 세트 (SL-04). 배치 순서는 글의 구조를 따라간다 - 본문에서 제목으로, 목록으로, 마지막에 구분 · 인용.
pub fn standard() -> Vec<SlashCommand> {
    vec![
        command("paragraph", "본문", "서식을 없애고 보통 문단으로", &["본문", "문단", "text", "paragraph", "normal"], "", BlockStyle::Paragraph),
        command("heading1", "제목 1", "가장 큰 제목", &["제목1", "제목", "heading1", "h1", "title"], "# ", BlockStyle::Heading { level: 1 }),
        command("heading2", "제목 2", "중간 크기 제목", &["제목2", "제목", "heading2", "h2"], "## ", BlockStyle::Heading { level: 2 }),
        command("heading3", "제목 3", "작은 제목", &["제목3", "제목", "heading3", "h3"], "### ", BlockStyle::Heading { level: 3 }),
        command("ordered", "번호 목록", "1, 2, 3으로 이어지는 목록", &["번호", "숫자", "목록", "ordered", "number"], "1. ", BlockStyle::Ordered { indent: 0, number: 1 }),
        command("bullet", "글머리 목록", "점으로 시작하는 목록", &["글머리", "목록", "리스트", "bullet", "list"], "- ", BlockStyle::Bullet { indent: 0 }),
        command("checkbox", "체크박스", "클릭해서 체크하는 할 일 목록", &["체크박스", "할일", "todo", "checkbox", "check"], "[] ", BlockStyle::Checkbox { indent: 0, checked: false }),
        command("divider", "구분선", "가로줄로 구역을 나눕니다", &["구분선", "구분", "선", "divider", "line", "hr"], "---", BlockStyle::Divider),
        command("quote", "인용", "인용문으로 표시", &["인용", "따옴", "quote"], "> ", BlockStyle::Quote),
        command("table", "표", "칸을 나눠 정리하는 표를 넣습니다", &["표", "테이블", "table", "grid"], "", BlockStyle::TableRow),
        command("codeBlock", "코드 박스", "여러 줄 코드를 상자에 담아 표시", &["코드", "코드블록", "코드박스", "code", "codeblock", "박스"], "``` ", BlockStyle::CodeBlock),
    ]
}

/// 글자 서식은 블록이 아니라 감싸는 기호로 넣는다. 팝업 아래쪽에 안내로만 보여 준다.
pub const INLINE_HINTS: [(&str, &str); 5] = [("굵게", "**글자**"), ("기울임", "*글자*"), ("취소선", "~~글자~~"), ("형광", "==글자=="), ("코드", "`글자`")];

/// 입력한 글자로 목록을 좁힌다 (SL-02). 앞에서부터 일치하는 것을 먼저 보여준다.
pub fn filter(query: &str, commands: &[SlashCommand]) -> Vec<SlashCommand> {
    let needle = text::lowercased(text::trim_ws(query));
    if needle.is_empty() {
        return commands.to_vec();
    }
    let needle_chars = chars(&needle);

    let mut prefix_matches = Vec::new();
    let mut contains_matches = Vec::new();
    for command in commands {
        let haystacks: Vec<String> = std::iter::once(&command.title).chain(command.keywords.iter()).map(|h| text::lowercased(h)).collect();
        if haystacks.iter().any(|h| text::has_prefix(h, &needle)) {
            prefix_matches.push(command.clone());
        } else if haystacks.iter().any(|h| text::contains_seq(&chars(h), &needle_chars)) {
            contains_matches.push(command.clone());
        }
    }
    prefix_matches.extend(contains_matches);
    prefix_matches
}

/// 기본 명령 세트에서 좁힌다.
pub fn filter_standard(query: &str) -> Vec<SlashCommand> {
    filter(query, &standard())
}
