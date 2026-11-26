//! MDemo 마크다운 엔진(맥 · Windows 공통). Swift `MarkdownEngine` 패키지와 같은 이름 · 같은 규칙으로 옮긴 것이다.
//!
//! 순수 로직이며 UI에 의존하지 않는다. 글자 단위는 Swift `Character`(확장 문자소, 정규 동치)이고,
//! 그 규칙은 `text` 모듈에 모았다. 골든 비교(`markdown-cases.json`)와 차분 퍼즈로 Swift와 바이트 단위로 맞춘다.

pub mod image_name;
pub mod input_rule;
mod numeric_table;
pub mod ocr;
pub mod parser;
pub mod pasted;
pub mod serializer;
pub mod slash;
pub mod styled;
pub mod table;
pub mod text;

pub use input_rule::{InputRule, InputRuleContext, InputRuleMatch, InputRuleOutcome, InputRuleSet};
pub use serializer::Flavor;
pub use styled::{BlockStyle, InlineColor, InlineStyleTag, MarkdownImage, OrderedListMarker, StyledLine, StyledSpan};

#[cfg(test)]
mod tests;
