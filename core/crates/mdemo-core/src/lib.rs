//! MDemo 핵심(맥 · Windows 공통). 데이터 모델과 저장 파일의 Swift 호환 규칙.

/// 핵심 라이브러리 판 번호.
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    #[test]
    fn version_is_set() {
        assert!(!super::core_version().is_empty());
    }
}

pub mod board;
pub mod board_layout;
pub mod device_state;
pub mod frontmatter;
pub mod groups;
pub mod id;
pub mod json;
pub mod ledger;
pub mod link;
pub mod meta;

mod unicode;
