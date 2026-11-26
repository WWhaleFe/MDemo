//! 실제 앱의 P4 잠금 경계. 열쇠는 불투명 세션 안에만 둔다.
use super::repository::{CoreMemoMeta, CoreRepository, CoreRepositoryError, Keys, RepositoryClock};
use crate::secret_transfer::{SecretBytes, SecretText};
use mdemo_core::{
    id::MemoID,
    meta::MemoDate,
    store::{FileMemoRepository, StoreError},
};
use std::sync::{Arc, Mutex};
type Result<T> = std::result::Result<T, CoreRepositoryError>;

/// 세션 열쇠를 내보내지 않는 불투명 핸들이다.
#[derive(uniffi::Object)]
pub struct CoreLockSession {
    session: Arc<mdemo_crypto::MemoLockSession>,
}
#[uniffi::export]
impl CoreLockSession {
    pub fn seal(&self, data: SecretBytes, name: Option<String>) -> Result<Vec<u8>> {
        let data = data.0;
        self.session
            .seal(&data, name.as_deref())
            .map_err(|e| StoreError::from(e).into())
    }
    pub fn open(&self, data: SecretBytes, name: Option<String>) -> Result<SecretBytes> {
        let plain = self
            .session
            .open(&data.0, name.as_deref())
            .map_err(StoreError::from)?;
        Ok(SecretBytes(plain))
    }
    pub fn wrapped(
        &self,
        password: SecretBytes,
        salt: Vec<u8>,
        iterations: i64,
    ) -> Result<Vec<u8>> {
        let password = password.0;
        self.session
            .wrapped(&password, &salt, iterations)
            .map_err(|e| StoreError::from(e).into())
    }
    pub fn clear(&self) {
        self.session.clear();
    }
}

#[uniffi::export(with_foreign)]
pub trait CorePrivacyHook: Send + Sync {
    fn before_removal(&self, id: String) -> Result<()>;
}

/// 다음 작업의 ID는 실패한 작업에서도 남겨 두지 않고 새 설정으로 교체한다.
#[derive(Default)]
struct LockIds(Mutex<Option<String>>);
impl mdemo_core::store::IdSource for LockIds {
    fn next_id(&self, now: MemoDate) -> MemoID {
        self.0
            .lock()
            .unwrap()
            .take()
            .map(MemoID::new)
            .unwrap_or_else(|| {
                mdemo_core::store::IdSource::next_id(&mdemo_core::store::SystemIds, now)
            })
    }
}

/// 저장소와 같은 루트와 키체인을 쓰며 모든 잠금 변경을 직렬화한다.
#[derive(uniffi::Object)]
pub struct CoreLockStore {
    store: Mutex<mdemo_core::store::MemoStore>,
    clock: Arc<RepositoryClock>,
    ids: Arc<LockIds>,
    privacy_changed: Arc<std::sync::atomic::AtomicBool>,
}
#[uniffi::export]
impl CoreRepository {
    pub fn lock_store(&self) -> Result<Arc<CoreLockStore>> {
        let clock = Arc::new(RepositoryClock::default());
        let ids = Arc::new(LockIds::default());
        let repo = FileMemoRepository::with_keys(
            self.repository.root(),
            clock.clone(),
            Arc::new(Keys(self.keys.clone())),
        )?;
        let mut store = mdemo_core::store::MemoStore::new(repo, clock.clone(), ids.clone());
        let privacy_changed = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = privacy_changed.clone();
        store.on_privacy_change = Some(Box::new(move || {
            flag.store(true, std::sync::atomic::Ordering::SeqCst);
        }));
        Ok(Arc::new(CoreLockStore {
            store: Mutex::new(store),
            clock,
            ids,
            privacy_changed,
        }))
    }
}
#[uniffi::export]
impl CoreLockStore {
    pub fn configure(
        &self,
        at: f64,
        next_id: Option<String>,
        iterations: i64,
        hook: Option<Arc<dyn CorePrivacyHook>>,
    ) {
        let mut store = self.store.lock().unwrap();
        *self.clock.0.lock().unwrap() = Some(at);
        *self.ids.0.lock().unwrap() = next_id;
        store.set_iteration_source(if iterations == 0 {
            Arc::new(mdemo_crypto::calibrated_iterations)
        } else {
            Arc::new(move || iterations)
        });
        store.before_privacy_removal = hook.map(|hook| {
            Box::new(move |id: &MemoID| {
                hook.before_removal(id.raw_value.clone())
                    .map_err(|e| StoreError::Other(e.to_string()))
            }) as Box<dyn FnMut(&MemoID) -> mdemo_core::store::StoreResult<()> + Send>
        });
        store.reload_summaries();
    }
    pub fn take_privacy_change(&self) -> bool {
        self.privacy_changed
            .swap(false, std::sync::atomic::Ordering::SeqCst)
    }
    pub fn unlock(&self, id: String, password: SecretBytes) -> Result<()> {
        let password = password.0;
        Ok(self
            .store
            .lock()
            .unwrap()
            .unlock(&MemoID::new(id), &password)?)
    }
    pub fn create_locked_memo(
        &self,
        password: SecretBytes,
        moving: Option<String>,
    ) -> Result<String> {
        let password = password.0;
        Ok(self
            .store
            .lock()
            .unwrap()
            .create_locked_memo(&password, moving.map(MemoID::new).as_ref())?
            .raw_value)
    }
    pub fn change_password(&self, id: String, password: SecretBytes) -> Result<()> {
        let password = password.0;
        Ok(self
            .store
            .lock()
            .unwrap()
            .change_password(&MemoID::new(id), &password)?)
    }
    pub fn move_to_plain_memo(&self, id: String) -> Result<String> {
        Ok(self
            .store
            .lock()
            .unwrap()
            .move_to_plain_memo(&MemoID::new(id))?
            .raw_value)
    }
    pub fn destroy_memo(&self, id: String) -> Result<()> {
        Ok(self.store.lock().unwrap().destroy_memo(&MemoID::new(id))?)
    }
    pub fn relock(&self, id: String) {
        self.store.lock().unwrap().relock(&MemoID::new(id));
    }
    pub fn lock_failure_count(&self, id: String) -> i64 {
        let mut store = self.store.lock().unwrap();
        store.reload_summaries();
        store.lock_failure_count(&MemoID::new(id))
    }
    pub fn lock_session(&self, id: String) -> Option<Arc<CoreLockSession>> {
        self.store
            .lock()
            .unwrap()
            .lock_session(&MemoID::new(id))
            .map(|session| Arc::new(CoreLockSession { session }))
    }
    pub fn decrypted_document(&self, id: String) -> Result<CoreDecryptedDocument> {
        let store = self.store.lock().unwrap();
        let d = store.decrypted_document(&MemoID::new(id))?;
        // 화면으로 넘기는 직렬화까지 본문을 Secret으로 유지한다.
        Ok(CoreDecryptedDocument {
            body: SecretText(d.body),
            meta: d.meta.into(),
            unknown_frontmatter_lines: d.unknown_frontmatter_lines,
            unknown_link_tokens: d.unknown_link_tokens,
        })
    }
    pub fn save_body(&self, id: String, body: SecretBytes, at: f64) -> bool {
        let body = body.0;
        let Ok(body) = std::str::from_utf8(&body) else {
            return false;
        };
        let mut store = self.store.lock().unwrap();
        *self.clock.0.lock().unwrap() = Some(at);
        store.save_body(&MemoID::new(id), body)
    }
}

#[derive(uniffi::Record)]
pub struct CoreDecryptedDocument {
    pub meta: CoreMemoMeta,
    pub body: SecretText,
    pub unknown_frontmatter_lines: Vec<String>,
    pub unknown_link_tokens: Vec<String>,
}
