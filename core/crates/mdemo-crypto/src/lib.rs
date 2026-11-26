//! 암호 메모의 암호 처리(P4). Swift `LockCrypto` · `MemoLockSession` · `MemoKeychain`의 Rust 판.
//!
//! 열쇠 · KEK · 암호 · 복호화한 본문은 `Zeroizing<Vec<u8>>`에만 둔다(배열은 옮길 때 복사본이 남아 쓰지 않는다).
//! 공개 API는 암호를 UTF-8 바이트(`&[u8]`)로 받는다. 상세한 한계는 `docs/hidden-behaviors.md`의 P4 항목을 본다.

mod crypto;
mod error;
mod key_store;
mod session;

pub use crypto::{
    calibrated_iterations, constant_time_equal, derive, filtered_password, open, random, seal, sha256,
    valid_password, MAXIMUM_ITERATIONS, MINIMUM_ITERATIONS, NONCE_LENGTH, TAG_LENGTH,
};
pub use error::LockError;
pub use key_store::{parse_failures, KeyStore, MemoryKeyStore};
pub use session::MemoLockSession;
pub use zeroize::{Zeroize, Zeroizing};

/// 비밀 바이트 버퍼. 떨어질 때 0으로 덮는다.
pub type Secret = Zeroizing<Vec<u8>>;

#[cfg(test)]
mod tests;
