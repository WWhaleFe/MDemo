//! Swift `LockCrypto`: 암호 규칙, 키 유도(PBKDF2-HMAC-SHA256), AES-256-GCM 봉인 · 개봉.

use crate::{error::LockError, Secret};
use aes_gcm::{
    aead::{AeadInPlace, KeyInit},
    Aes256Gcm, Nonce, Tag,
};
use sha2::{Digest, Sha256};
use std::time::Instant;
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

pub const MINIMUM_ITERATIONS: i64 = 2_000_000;
pub const MAXIMUM_ITERATIONS: i64 = 20_000_000;
/// CryptoKit `combined` 형식: nonce 12바이트 + 암호문 + 태그 16바이트.
pub const NONCE_LENGTH: usize = 12;
pub const TAG_LENGTH: usize = 16;

fn allowed(byte: u8) -> bool {
    byte.is_ascii_alphanumeric()
}

/// 4~6자(UTF-8 바이트 기준), 영문 대소문자와 숫자만.
pub fn valid_password(value: &[u8]) -> bool {
    (4..=6).contains(&value.len()) && value.iter().all(|b| allowed(*b))
}

/// 허용 글자만 남기고 앞 6바이트까지.
pub fn filtered_password(value: &[u8]) -> Secret {
    Zeroizing::new(value.iter().copied().filter(|b| allowed(*b)).take(6).collect())
}

/// 길이가 달라도 같은 시간이 걸리게 0으로 채워 비교한다. 길이 차이도 결과에 반영한다.
pub fn constant_time_equal(a: &[u8], b: &[u8]) -> bool {
    let count = a.len().max(b.len());
    let mut left = Zeroizing::new(vec![0u8; count]);
    let mut right = Zeroizing::new(vec![0u8; count]);
    left[..a.len()].copy_from_slice(a);
    right[..b.len()].copy_from_slice(b);
    let same_length = (a.len() as u64).ct_eq(&(b.len() as u64));
    bool::from(same_length & left.as_slice().ct_eq(right.as_slice()))
}

/// 운영체제 난수. 실패는 Swift처럼 열쇠 저장소 오류로 돌려준다.
pub fn random(count: usize) -> Result<Secret, LockError> {
    let mut data = Zeroizing::new(vec![0u8; count]);
    getrandom::getrandom(&mut data).map_err(|e| LockError::KeyStore(format!("난수 생성 실패: {e}")))?;
    Ok(data)
}

/// 평문 해시. 첨부 이동 검증에 쓴다. 해시는 비밀로 다루지 않는다.
pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn run_pbkdf2(password: &[u8], salt: &[u8], iterations: u32, output: &mut [u8]) {
    pbkdf2::pbkdf2_hmac::<Sha256>(password, salt, iterations, output);
}

/// 암호와 솔트에서 KEK(32바이트)를 만든다. 암호 형식 · 솔트 길이 · 반복 횟수가 틀리면 `Damaged`.
/// 암호 문자열을 직접 비교하지 않고, 맞는지는 AES-GCM 태그 인증에 맡긴다.
pub fn derive(password: &[u8], salt: &[u8], iterations: i64) -> Result<Secret, LockError> {
    if !valid_password(password) || salt.len() != 16 || !(MINIMUM_ITERATIONS..=MAXIMUM_ITERATIONS).contains(&iterations) {
        return Err(LockError::Damaged);
    }
    let mut result = Zeroizing::new(vec![0u8; 32]);
    run_pbkdf2(password, salt, iterations as u32, &mut result);
    Ok(result)
}

/// 이 기기에서 500ms가 걸리는 반복 횟수(200만 이상 2천만 이하). CommonCrypto의 `CCCalibratePBKDF`처럼
/// 짧게 재서 비례 계산한다(6바이트 암호, 16바이트 솔트, 32바이트 출력).
pub fn calibrated_iterations() -> i64 {
    const PROBE: u32 = 200_000;
    let mut out = Zeroizing::new(vec![0u8; 32]);
    run_pbkdf2(b"Calib1", &[0x5a; 16], 1_000, &mut out); // 첫 호출의 CPU 기능 감지 비용을 뺀다
    let started = Instant::now();
    run_pbkdf2(b"Calib1", &[0x5a; 16], PROBE, &mut out);
    let nanos = started.elapsed().as_nanos().max(1);
    let estimate = (PROBE as u128 * 500_000_000 / nanos).min(i64::MAX as u128) as i64;
    estimate.clamp(MINIMUM_ITERATIONS, MAXIMUM_ITERATIONS)
}

fn cipher(key: &[u8]) -> Result<Aes256Gcm, LockError> {
    if key.len() != 32 {
        return Err(LockError::Locked);
    }
    Aes256Gcm::new_from_slice(key).map_err(|_| LockError::Locked)
}

/// nonce(무작위 12바이트) + 암호문 + 태그. 연관 데이터는 `context`의 UTF-8.
/// 출력 버퍼에 평문을 넣고 제자리에서 암호화하므로 평문이 남는 별도 복사본이 없다.
pub fn seal(plaintext: &[u8], key: &[u8], context: &str) -> Result<Vec<u8>, LockError> {
    let cipher = cipher(key)?;
    // 암호화가 끝나기 전 오류로 떨어져도 평문이 남지 않도록 0으로 지우는 버퍼에 담는다(Gemini 교차 검수 지적).
    let mut combined = Zeroizing::new(Vec::with_capacity(NONCE_LENGTH + plaintext.len() + TAG_LENGTH));
    combined.resize(NONCE_LENGTH, 0);
    getrandom::getrandom(&mut combined[..NONCE_LENGTH]).map_err(|e| LockError::KeyStore(format!("난수 생성 실패: {e}")))?;
    combined.extend_from_slice(plaintext);
    let nonce = Nonce::clone_from_slice(&combined[..NONCE_LENGTH]);
    let tag = cipher
        .encrypt_in_place_detached(&nonce, context.as_bytes(), &mut combined[NONCE_LENGTH..])
        .map_err(|_| LockError::Authentication)?;
    combined.extend_from_slice(&tag);
    Ok(std::mem::take(&mut *combined))
}

/// `seal`의 반대. 태그가 맞지 않으면 `Authentication`, 너무 짧으면 `IncorrectSize`.
/// 복호화는 태그 확인 뒤에 일어나며, 결과 버퍼는 떨어질 때 0으로 덮인다.
pub fn open(ciphertext: &[u8], key: &[u8], context: &str) -> Result<Secret, LockError> {
    let cipher = cipher(key)?;
    if ciphertext.len() < NONCE_LENGTH + TAG_LENGTH {
        return Err(LockError::IncorrectSize);
    }
    let (nonce, rest) = ciphertext.split_at(NONCE_LENGTH);
    let (body, tag) = rest.split_at(rest.len() - TAG_LENGTH);
    let mut plain = Zeroizing::new(body.to_vec());
    cipher
        .decrypt_in_place_detached(Nonce::from_slice(nonce), context.as_bytes(), &mut plain, Tag::from_slice(tag))
        .map_err(|_| LockError::Authentication)?;
    Ok(plain)
}

#[cfg(test)]
pub(crate) fn run_pbkdf2_for_tests(password: &[u8], salt: &[u8], iterations: u32, output: &mut [u8]) {
    run_pbkdf2(password, salt, iterations, output)
}
