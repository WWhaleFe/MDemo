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
