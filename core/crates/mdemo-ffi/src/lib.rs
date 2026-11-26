//! Swift(UniFFI)로 내보내는 얇은 층. 화면 코드는 이 층을 직접 부르지 않고 CoreBridge를 거친다.
uniffi::setup_scaffolding!();

#[uniffi::export]
pub fn core_version() -> String {
    mdemo_core::core_version()
}

/// 연결 확인용: 받은 값을 그대로 돌려준다.
#[uniffi::export]
pub fn ping(value: u32) -> u32 {
    value
}

/// 입력 규칙이 바꿀 구간과 결과. 위치는 모두 문자(확장 문자소) 단위다.
#[derive(uniffi::Record)]
pub struct InputRuleMatchFfi {
    pub range_start: u32,
    pub range_end: u32,
    pub replacement: String,
    pub outcome: InputRuleOutcomeFfi,
}

/// 입력 규칙 결과. 블록 서식은 문단 상태에서 걸리는 것만 있다.
#[derive(uniffi::Enum)]
pub enum InputRuleOutcomeFfi {
    Heading { level: u32 },
    Bullet { indent: u32 },
    Ordered { indent: u32, number: i64 },
    Checkbox { indent: u32, checked: bool },
    CodeBlock,
    /// 글자 서식 비트 집합(굵게 1, 기울임 2, 취소선 4, 형광 8, 코드 16).
    Inline { styles: u32 },
}

fn input_rules() -> &'static mdemo_markdown::InputRuleSet {
    static RULES: std::sync::OnceLock<mdemo_markdown::InputRuleSet> = std::sync::OnceLock::new();
    RULES.get_or_init(mdemo_markdown::InputRuleSet::m1)
}

/// 문단 상태의 줄에서 첫 번째로 걸리는 입력 규칙(Swift `InputRuleSet.m1.firstMatch(line:caretOffset:)`).
/// `caret_offset`은 문자(확장 문자소) 단위다. 걸리는 규칙이 없으면 None.
#[uniffi::export]
pub fn input_rule_first_match(line: String, caret_offset: u32) -> Option<InputRuleMatchFfi> {
    use mdemo_markdown::{BlockStyle, InputRuleOutcome};
    let m = input_rules().first_match_line(&line, caret_offset as usize)?;
    let outcome = match m.outcome {
        InputRuleOutcome::Block(BlockStyle::Heading { level }) => InputRuleOutcomeFfi::Heading { level: level as u32 },
        InputRuleOutcome::Block(BlockStyle::Bullet { indent }) => InputRuleOutcomeFfi::Bullet { indent: indent as u32 },
        InputRuleOutcome::Block(BlockStyle::Ordered { indent, number }) => InputRuleOutcomeFfi::Ordered { indent: indent as u32, number },
        InputRuleOutcome::Block(BlockStyle::Checkbox { indent, checked }) => InputRuleOutcomeFfi::Checkbox { indent: indent as u32, checked },
        InputRuleOutcome::Block(_) => InputRuleOutcomeFfi::CodeBlock,
        InputRuleOutcome::Inline(styles) => InputRuleOutcomeFfi::Inline { styles: styles.0 },
    };
    Some(InputRuleMatchFfi { range_start: m.range.start as u32, range_end: m.range.end as u32, replacement: m.replacement, outcome })
}

mod shadow;
pub use shadow::*;
