//! 열려 있는 창의 열쇠 (Swift `MemoLockSession`). 이미지 작업과 잠금이 겹쳐도 직렬화한다.
//!
//! context 규칙(연관 데이터): 본문 `<ID>/body`, 첨부 `<ID>/attachment/<이름>`, 감싼 열쇠 `<ID>/key`.
//! 첨부 파일은 디스크에 `<이름>.enc`로 둔다(이름은 호출자 몫).

use crate::{crypto, error::LockError, Secret};
use std::sync::{Mutex, MutexGuard};
use zeroize::Zeroize;

pub struct MemoLockSession {
    id: String,
    key: Mutex<Secret>,
}

impl MemoLockSession {
    /// 열쇠 버퍼를 넘겨받는다(복사하지 않는다).
    pub fn new(id: &str, key: Secret) -> Self {
        Self { id: id.into(), key: Mutex::new(key) }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    fn key(&self) -> MutexGuard<'_, Secret> {
        self.key.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn context(&self, name: Option<&str>) -> String {
        match name {
            Some(name) => format!("{}/attachment/{name}", self.id),
            None => format!("{}/body", self.id),
        }
    }

    pub fn seal(&self, data: &[u8], name: Option<&str>) -> Result<Vec<u8>, LockError> {
        let key = self.key();
        crypto::seal(data, &key, &self.context(name))
    }

    pub fn open(&self, data: &[u8], name: Option<&str>) -> Result<Secret, LockError> {
        let key = self.key();
        crypto::open(data, &key, &self.context(name))
    }

    /// KEK = derive(암호, 솔트, 반복 횟수)로 세션 열쇠를 감싼다. 키 유도 중에는 잠그지 않는다.
    pub fn wrapped(&self, password: &[u8], salt: &[u8], iterations: i64) -> Result<Vec<u8>, LockError> {
        let kek = crypto::derive(password, salt, iterations)?;
        let key = self.key();
        if key.len() != 32 {
            return Err(LockError::Locked);
        }
        crypto::seal(&key, &kek, &format!("{}/key", self.id))
    }

    /// 열쇠를 0으로 덮고 비운다. 이후 봉인 · 개봉은 `Locked`.
    pub fn clear(&self) {
        self.key().zeroize();
    }

    #[cfg(test)]
    pub(crate) fn key_buffer(&self) -> (*const u8, usize) {
        let key = self.key();
        (key.as_ptr(), key.capacity())
    }
}
