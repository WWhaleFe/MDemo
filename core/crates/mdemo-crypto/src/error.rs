use std::fmt;

/// Swift `MemoLockError`와 CryptoKit 오류를 합친 것.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LockError {
    InvalidPassword,
    MissingKey,
    WrongPassword,
    Damaged,
    Locked,
    Destroyed,
    /// 키체인(열쇠 저장소)이나 난수 생성 실패. Swift `.keychain(OSStatus)`.
    KeyStore(String),
    /// AES-GCM 태그 불일치 (Swift `CryptoKitError.authenticationFailure`). `MemoLockError`가 아니라서
    /// 호출자가 따로 잡지 않으면 `damaged`로 바뀌지 않고 그대로 올라간다.
    Authentication,
    /// 암호문이 nonce + 태그보다 짧다 (Swift `CryptoKitError.incorrectParameterSize`).
    IncorrectSize,
}

impl fmt::Display for LockError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::InvalidPassword => "4~6자, 영문 대소문자와 숫자",
            Self::MissingKey => "이 맥에서 만든 잠긴 메모가 아니거나 열쇠가 없어 열 수 없습니다",
            Self::WrongPassword => "암호가 맞지 않습니다",
            Self::Damaged => "암호 메모가 손상되어 열 수 없습니다",
            Self::Locked => "먼저 암호 메모를 열어 주세요",
            Self::Destroyed => "이 메모는 파기되었습니다",
            Self::KeyStore(_) => "이 맥 키체인에 접근하지 못했습니다",
            Self::Authentication => "인증에 실패했습니다",
            Self::IncorrectSize => "암호문 길이가 맞지 않습니다",
        })
    }
}

impl std::error::Error for LockError {}
