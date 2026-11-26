//! 열쇠 저장소 계약 (Swift `MemoKeychain`). 감싼 열쇠와 `<ID>.failures`(문자열 정수)를 ID별로 둔다.
//!
//! - 맥 키체인 어댑터는 P7에서 Swift 콜백으로 연결하므로 이번에는 트레이트와 메모리 구현만 둔다.
//! - Windows 자격 증명 관리자 어댑터(P8) 설계 메모는 아래 `windows_credential_manager` 모듈 주석에 있다.
//! - 감싼 열쇠는 암호문이라 비밀 버퍼로 다루지 않는다.

use crate::error::LockError;
use std::{collections::BTreeMap, sync::Mutex};

pub trait KeyStore: Send + Sync {
    fn read_key(&self, id: &str) -> Result<Option<Vec<u8>>, LockError>;
    fn write_key(&self, id: &str, wrapped: &[u8]) -> Result<(), LockError>;
    fn delete_key(&self, id: &str) -> Result<(), LockError>;
    /// 없으면 0. 저장된 글자가 0 이상의 정수가 아니면 `Damaged`.
    fn read_failures(&self, id: &str) -> Result<i64, LockError>;
    fn write_failures(&self, id: &str, failures: i64) -> Result<(), LockError>;
    fn delete_failures(&self, id: &str) -> Result<(), LockError>;

    /// Swift `delete(id:)`: 열쇠를 지운 다음 실패 횟수를 지운다. 앞쪽이 실패하면 뒤쪽은 건드리지 않는다.
    fn delete(&self, id: &str) -> Result<(), LockError> {
        self.delete_key(id)?;
        self.delete_failures(id)
    }
}

/// `<ID>.failures`에 저장된 글자를 읽는다 (Swift: UTF-8 문자열 → `Int` → 0 이상).
pub fn parse_failures(raw: &[u8]) -> Result<i64, LockError> {
    let text = std::str::from_utf8(raw).map_err(|_| LockError::Damaged)?;
    match text.parse::<i64>() {
        Ok(count) if count >= 0 => Ok(count),
        _ => Err(LockError::Damaged),
    }
}

/// 시험 · 시나리오용 메모리 구현. 실패 횟수는 Swift 키체인처럼 글자 그대로 저장한다.
#[derive(Default)]
pub struct MemoryKeyStore {
    state: Mutex<MemoryState>,
}

#[derive(Default, Clone)]
struct MemoryState {
    keys: BTreeMap<String, Vec<u8>>,
    failures: BTreeMap<String, Vec<u8>>,
}

type Parts = (BTreeMap<String, Vec<u8>>, BTreeMap<String, Vec<u8>>);

impl MemoryKeyStore {
    pub fn from_parts(keys: BTreeMap<String, Vec<u8>>, failures: BTreeMap<String, Vec<u8>>) -> Self {
        Self { state: Mutex::new(MemoryState { keys, failures }) }
    }

    /// (열쇠, 실패 횟수 원본 글자)의 복사본. 시나리오가 `keychain.json`으로 내보낸다.
    pub fn snapshot(&self) -> Parts {
        let state = self.lock();
        (state.keys.clone(), state.failures.clone())
    }

    /// 손상된 횟수 글자를 심는 시험용 통로.
    pub fn write_raw_failures(&self, id: &str, raw: &[u8]) {
        self.lock().failures.insert(id.into(), raw.to_vec());
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, MemoryState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl KeyStore for MemoryKeyStore {
    fn read_key(&self, id: &str) -> Result<Option<Vec<u8>>, LockError> {
        Ok(self.lock().keys.get(id).cloned())
    }
    fn write_key(&self, id: &str, wrapped: &[u8]) -> Result<(), LockError> {
        self.lock().keys.insert(id.into(), wrapped.to_vec());
        Ok(())
    }
    fn delete_key(&self, id: &str) -> Result<(), LockError> {
        self.lock().keys.remove(id);
        Ok(())
    }
    fn read_failures(&self, id: &str) -> Result<i64, LockError> {
        match self.lock().failures.get(id) {
            Some(raw) => parse_failures(raw),
            None => Ok(0),
        }
    }
    fn write_failures(&self, id: &str, failures: i64) -> Result<(), LockError> {
        self.lock().failures.insert(id.into(), failures.to_string().into_bytes());
        Ok(())
    }
    fn delete_failures(&self, id: &str) -> Result<(), LockError> {
        self.lock().failures.remove(id);
        Ok(())
    }
}

/// Windows 자격 증명 관리자 어댑터 자리 표시 (P8).
///
/// 설계 메모:
/// - 대상 이름은 Swift 키체인의 service/account를 따라 `com.wwhalefe.MDemo.lock/<ID>`와
///   `com.wwhalefe.MDemo.lock/<ID>.failures`로 한다. 종류는 `CRED_TYPE_GENERIC`.
/// - 보존은 `CRED_PERSIST_LOCAL_MACHINE`(로밍 · 동기화 제외, 이 PC에만). 맥의 `ThisDeviceOnly`와 같은 뜻이다.
/// - `CredWriteW`는 같은 이름이면 덮어쓰므로 Swift의 update-or-add와 같다. 삭제는 `CredDeleteW`이고
///   `ERROR_NOT_FOUND`는 성공으로 본다(Swift: 항목이 없으면 성공).
/// - 자격 증명 블롭은 2560바이트 제한이 있다. 감싼 열쇠는 12 + 32 + 16 = 60바이트라 들어간다.
/// - 쓰는 쪽 프로세스 메모리의 블롭 복사본도 `Zeroizing`으로 다룬다.
#[cfg(windows)]
pub mod windows_credential_manager {
    // P8에서 구현한다. 지금은 트레이트만 있고 어댑터가 없다.
}
