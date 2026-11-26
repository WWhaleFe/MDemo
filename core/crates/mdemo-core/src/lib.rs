//! MDemo 핵심(맥 · Windows 공통). P1에서는 연결 확인용 함수만 둔다.

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
