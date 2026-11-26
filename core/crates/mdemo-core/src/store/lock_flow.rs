//! 잠긴 메모의 흐름 (Swift `MemoStore`의 잠금 부분, 약 500~740행). 순서와 예외 경로를 Swift 그대로 옮겼다.
//!
//! Swift와 다른 점(모두 `docs/hidden-behaviors.md`에 있다).
//! - `unlock` · `create_locked_memo` · `change_password`는 `async`가 아니라 호출한 스레드에서 끝까지 일한다.
//!   Swift의 `unlocking` 중복 방지는 `&mut self`가 대신하므로 두지 않았다. 백그라운드 실행은 P7에서 정한다.
//! - 암호는 `&[u8]`, 복호화한 본문은 `Secret`(0으로 덮이는 버퍼)로만 다룬다.
//!
//! 평문이 남는 곳(`Wiped`로 줄였지만 완전히 없애지는 못한다)
//! - 일반 메모를 잠글 때 읽는 원본 `MemoDocument.body`(`String`)와 그것을 다시 읽어 비교하는 복사본.
//!   원본이 이미 평문 파일이라 새 노출은 아니지만, 메모리 복사본은 떨어질 때 0으로 덮는다.
//! - 잠금을 일반 메모로 옮길 때의 `MemoDocument`와 `frontmatter::encode`가 만드는 `String`.
//!   `encode` 내부의 임시 문자열은 우리가 덮을 수 없다.

use super::{
    atomic_write, b64,
    memo_store::MemoStore,
    secure_delete,
    summary::{prefix_characters, PREVIEW_CHARACTER_LIMIT},
    StoreError, StoreResult,
};
use crate::{
    frontmatter::{trim, MemoDocument},
    id::MemoID,
    meta::MemoMeta,
};
use mdemo_crypto::{
    derive, open, random, sha256, valid_password, MemoLockSession, Secret, Zeroize, Zeroizing, MAXIMUM_ITERATIONS,
    MINIMUM_ITERATIONS,
};
use std::{collections::BTreeMap, collections::BTreeSet, fs, path::Path, path::PathBuf, sync::Arc};

/// 복호화한 문서. 본문은 UTF-8로 확인된 바이트이며 떨어질 때 0으로 덮인다.
pub struct DecryptedDocument {
    pub meta: MemoMeta,
    pub body: Secret,
    pub unknown_frontmatter_lines: Vec<String>,
    pub unknown_link_tokens: Vec<String>,
}

impl DecryptedDocument {
    /// 본문을 복사하지 않고 빌려 본다.
    pub fn body_str(&self) -> &str {
        std::str::from_utf8(&self.body).unwrap_or("")
    }
}

/// 평문 본문을 가진 문서를 떨어질 때 덮는다.
struct Wiped(MemoDocument);
impl Drop for Wiped {
    fn drop(&mut self) {
        self.0.body.zeroize();
    }
}

fn is_regular_file(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_file())
}

impl MemoStore {
    pub(super) fn fire_privacy_change(&mut self) {
        if let Some(hook) = self.on_privacy_change.as_mut() {
            hook();
        }
    }

    fn memo_folder(&self, id: &MemoID) -> PathBuf {
        self.repo.memo_directory(id)
    }

    pub fn lock_failure_count(&self, id: &MemoID) -> i64 {
        let in_header = self.summaries.iter().find(|s| s.meta.id == *id).and_then(|s| s.meta.lock_failures).unwrap_or(0);
        in_header.max(self.repo.key_store().read_failures(&id.raw_value).unwrap_or(0))
    }

    pub fn lock_session(&self, id: &MemoID) -> Option<Arc<MemoLockSession>> {
        self.sessions.get(id).cloned()
    }

    /// 열쇠를 지우고 요약의 미리보기를 비운다(일반 메모여도 비운다 - Swift와 같다).
    pub fn relock(&mut self, id: &MemoID) {
        if let Some(session) = self.sessions.remove(id) {
            session.clear();
        }
        if let Some(meta) = self.summaries.iter().find(|s| s.meta.id == *id).map(|s| s.meta.clone()) {
            self.update_summary(meta, String::new());
        }
    }

    pub fn decrypted_document(&self, id: &MemoID) -> StoreResult<DecryptedDocument> {
        let document = self.repo.load(id)?;
        if !document.meta.is_locked {
            return Ok(DecryptedDocument {
                meta: document.meta,
                body: Zeroizing::new(document.body.into_bytes()),
                unknown_frontmatter_lines: document.unknown_frontmatter_lines,
                unknown_link_tokens: document.unknown_link_tokens,
            });
        }
        let session = self.sessions.get(id).ok_or(StoreError::Locked)?;
        let cipher = b64::decode(&document.body).ok_or(StoreError::Locked)?;
        let plain = session.open(&cipher, None)?;
        if std::str::from_utf8(&plain).is_err() {
            return Err(StoreError::Damaged);
        }
        Ok(DecryptedDocument {
            meta: document.meta,
            body: plain,
            unknown_frontmatter_lines: document.unknown_frontmatter_lines,
            unknown_link_tokens: document.unknown_link_tokens,
        })
    }

    /// 잠금을 푼다. 실패 횟수 규칙은 Swift 그대로다.
    /// - 횟수 = max(앞머리 `lockFailures`, 열쇠 저장소 failures). 10 이상이면 파기.
    /// - 시도 전에 failures + 1을 기록하고, 열쇠가 맞으면 되돌린다.
    /// - 암호 형식이 틀리면 시도로 세지 않는다(`WrongPassword`만 돌려준다).
    /// - 열쇠는 맞는데 본문이 손상되면 횟수를 올리지 않고 `Damaged`.
    pub fn unlock(&mut self, id: &MemoID, password: &[u8]) -> StoreResult<()> {
        if !valid_password(password) {
            return Err(StoreError::WrongPassword);
        }
        let keys = self.repo.key_store().clone();
        let key_id = id.raw_value.as_str();
        let mut document = self.repo.load(id)?;
        let salt = document.meta.lock_salt.as_deref().and_then(b64::decode);
        let (Some(salt), Some(iterations), true, true) =
            (salt, document.meta.lock_iterations, document.meta.is_locked, document.meta.lock_version == Some(1))
        else {
            return Err(StoreError::Damaged);
        };
        let failures = document.meta.lock_failures.unwrap_or(0).max(keys.read_failures(key_id)?);
        if failures >= 10 {
            self.destroy_memo(id)?;
            return Err(StoreError::Destroyed);
        }
        let wrapped = keys.read_key(key_id)?.ok_or(StoreError::MissingKey)?;
        // 결과가 나오기 전에 시도를 기록한다. 인증 성공이나 본문 손상 때 아래에서 복구한다.
        if salt.len() != 16 || !(MINIMUM_ITERATIONS..=MAXIMUM_ITERATIONS).contains(&iterations) || wrapped.len() < 28 {
            return Err(StoreError::Damaged);
        }
        keys.write_failures(key_id, failures + 1)?;
        let derived = derive(password, &salt, iterations).and_then(|kek| open(&wrapped, &kek, &format!("{key_id}/key")));
        let key = match derived {
            Ok(key) => key,
            Err(mdemo_crypto::LockError::Authentication) => {
                document = self.repo.load(id)?;
                document.meta.lock_failures = Some(failures + 1);
                self.repo.save(&document)?;
                self.update_summary(document.meta, String::new());
                if failures + 1 >= 10 {
                    self.destroy_memo(id)?;
                    return Err(StoreError::Destroyed);
                }
                return Err(StoreError::WrongPassword);
            }
            Err(other) => {
                keys.write_failures(key_id, failures)?;
                return Err(other.into());
            }
        };
        keys.write_failures(key_id, failures)?;
        document = self.repo.load(id)?;
        let session = Arc::new(MemoLockSession::new(key_id, key));
        let cipher = b64::decode(&document.body).ok_or(StoreError::Damaged)?;
        match session.open(&cipher, None) {
            Ok(verification) if std::str::from_utf8(&verification).is_ok() => {}
            _ => return Err(StoreError::Damaged),
        }
        document.meta.lock_failures = Some(0);
        keys.write_failures(key_id, 0)?;
        self.repo.save(&document)?;
        if let Some(old) = self.sessions.insert(id.clone(), session) {
            old.clear();
        }
        self.update_summary(document.meta, String::new());
        Ok(())
    }

    /// 새 ID에는 첫 기록부터 암호문만 쓴다. 원본은 검증을 모두 마치기 전에는 건드리지 않는다.
    pub fn create_locked_memo(&mut self, password: &[u8], moving: Option<&MemoID>) -> StoreResult<MemoID> {
        if !valid_password(password) {
            return Err(StoreError::InvalidPassword);
        }
        let original = match moving {
            Some(source) => Some(Wiped(self.repo.load(source)?)),
            None => None,
        };
        if original.as_ref().is_some_and(|o| o.0.meta.is_locked) {
            return Err(StoreError::Locked);
        }
        let now = self.clock.now();
        let id = self.ids.next_id(now);
        // 평문 본문은 복사하지 않는다(새 문서의 본문은 아래에서 암호문으로 채운다).
        let mut document = match &original {
            Some(o) => MemoDocument {
                meta: o.0.meta.clone(),
                body: String::new(),
                unknown_frontmatter_lines: o.0.unknown_frontmatter_lines.clone(),
                unknown_link_tokens: Vec::new(),
            },
            None => MemoDocument {
                meta: MemoMeta::new(MemoID::new(String::new())),
                body: String::new(),
                unknown_frontmatter_lines: Vec::new(),
                unknown_link_tokens: Vec::new(),
            },
        };
        document.meta.id = id.clone();
        // 직접 붙인 제목만 가져온다. 제목이 없는 메모의 "보이는 제목"은 본문 첫 줄이라,
        // 그것을 평문 제목으로 적으면 본문 일부가 암호 밖으로 새어 나간다.
        document.meta.title =
            original.as_ref().and_then(|o| o.0.meta.title.clone()).filter(|title| !trim(title).is_empty());
        document.meta.created = self.clock.now();
        document.meta.modified = self.clock.now();
        document.meta.links = Vec::new();
        document.meta.conflict_of = None;
        document.meta.is_locked = true;
        document.meta.is_open = true;
        let salt = random(16)?;
        document.meta.lock_salt = Some(b64::encode(&salt));
        let iterations = (self.calibrate)();
        document.meta.lock_iterations = Some(iterations);
        document.meta.lock_version = Some(1);
        document.meta.lock_failures = Some(0);
        let session = Arc::new(MemoLockSession::new(&id.raw_value, random(32)?));
        let steps = self.create_locked_steps(
            &id,
            password,
            &salt,
            iterations,
            &session,
            &mut document,
            moving,
            original.as_ref().map(|o| &o.0),
        );
        if let Err(error) = steps {
            session.clear();
            let _ = self.repo.key_store().delete(&id.raw_value);
            let _ = secure_delete::remove(&self.memo_folder(&id), None);
            return Err(error);
        }
        self.sessions.insert(id.clone(), session);
        self.update_summary(document.meta, String::new());
        if let Some(source) = moving {
            self.destroy_memo(source)?;
        }
        Ok(id)
    }

    #[allow(clippy::too_many_arguments)]
    fn create_locked_steps(
        &self,
        id: &MemoID,
        password: &[u8],
        salt: &[u8],
        iterations: i64,
        session: &Arc<MemoLockSession>,
        document: &mut MemoDocument,
        source: Option<&MemoID>,
        original: Option<&MemoDocument>,
    ) -> StoreResult<()> {
        let keys = self.repo.key_store();
        let wrapped = session.wrapped(password, salt, iterations)?;
        keys.write_key(&id.raw_value, &wrapped)?;
        self.repo.ledger_insert(id, "local-only")?;
        let original_body = original.map_or("", |o| o.body.as_str());
        document.body = b64::encode(&session.seal(original_body.as_bytes(), None)?);
        self.repo.save(document)?;
        let to = self.repo.attachments_directory(id);
        fs::create_dir_all(&to)?;
        let mut hashes: BTreeMap<String, [u8; 32]> = BTreeMap::new();
        if let Some(source) = source {
            let from = self.repo.attachments_directory(source);
            fs::create_dir_all(&to)?;
            let files = if from.exists() { read_all(&from)? } else { Vec::new() };
            for path in files {
                if !is_regular_file(&path) {
                    return Err(StoreError::Damaged);
                }
                let name = file_name(&path);
                let plain = Zeroizing::new(fs::read(&path)?);
                hashes.insert(name.clone(), sha256(&plain));
                let cipher = session.seal(&plain, Some(&name))?;
                let target = to.join(format!("{name}.enc"));
                atomic_write(&target, &cipher)?;
                let verified = session.open(&fs::read(&target)?, Some(&name))?;
                if verified.as_slice() != plain.as_slice() {
                    return Err(StoreError::Damaged);
                }
            }
            if !self.same_as(source, original)? {
                return Err(StoreError::Damaged);
            }
        }
        secure_delete::synchronize(&self.memo_folder(id))?;
        let saved = self.repo.load(id)?;
        let persisted = keys.read_key(&id.raw_value)?.ok_or(StoreError::MissingKey)?;
        let kek = derive(password, salt, iterations)?;
        let reopened = MemoLockSession::new(&id.raw_value, open(&persisted, &kek, &format!("{}/key", id.raw_value))?);
        drop(kek);
        let verified = reopened.open(&b64::decode(&saved.body).ok_or(StoreError::Damaged)?, None)?;
        if verified.as_slice() != original_body.as_bytes() {
            return Err(StoreError::Damaged);
        }
        for (name, hash) in &hashes {
            let bytes = reopened.open(&fs::read(to.join(format!("{name}.enc")))?, Some(name))?;
            if sha256(&bytes) != *hash {
                return Err(StoreError::Damaged);
            }
        }
        if let Some(source) = source {
            if !self.same_as(source, original)? {
                return Err(StoreError::Damaged);
            }
            let from = self.repo.attachments_directory(source);
            let files = if from.exists() { read_all(&from)? } else { Vec::new() };
            let names: BTreeSet<String> = files.iter().map(|p| file_name(p)).collect();
            if names != hashes.keys().cloned().collect::<BTreeSet<_>>() {
                return Err(StoreError::Damaged);
            }
            for path in files {
                let bytes = Zeroizing::new(fs::read(&path)?);
                if hashes.get(&file_name(&path)) != Some(&sha256(&bytes)) {
                    return Err(StoreError::Damaged);
                }
            }
        }
        Ok(())
    }

    fn same_as(&self, id: &MemoID, original: Option<&MemoDocument>) -> StoreResult<bool> {
        let loaded = Wiped(self.repo.load(id)?);
        Ok(original.is_some_and(|o| loaded.0 == *o))
    }

    /// 새 암호로 열쇠를 다시 감싼다. 실패 횟수와 수정 시각은 그대로다.
    pub fn change_password(&mut self, id: &MemoID, password: &[u8]) -> StoreResult<()> {
        if !valid_password(password) {
            return Err(StoreError::InvalidPassword);
        }
        let session = self.sessions.get(id).cloned().ok_or(StoreError::Locked)?;
        let keys = self.repo.key_store().clone();
        let previous = keys.read_key(&id.raw_value)?.ok_or(StoreError::MissingKey)?;
        let salt = random(16)?;
        let iterations = (self.calibrate)();
        let wrapped = session.wrapped(password, &salt, iterations)?;
        let mut document = self.repo.load(id)?;
        keys.write_key(&id.raw_value, &wrapped)?;
        document.meta.lock_salt = Some(b64::encode(&salt));
        document.meta.lock_iterations = Some(iterations);
        if let Err(error) = self.repo.save(&document) {
            keys.write_key(&id.raw_value, &previous)?;
            return Err(error);
        }
        self.update_summary(document.meta, String::new());
        Ok(())
    }

    /// 열린 잠긴 메모를 새 ID의 일반 메모로 옮기고 잠긴 메모는 파기한다.
    pub fn move_to_plain_memo(&mut self, id: &MemoID) -> StoreResult<MemoID> {
        let decrypted = self.decrypted_document(id)?;
        let session = match self.sessions.get(id) {
            Some(session) if decrypted.meta.is_locked => session.clone(),
            _ => return Err(StoreError::Locked),
        };
        let new_id = self.ids.next_id(self.clock.now());
        let mut meta = decrypted.meta.clone();
        meta.id = new_id.clone();
        meta.is_locked = false;
        meta.lock_salt = None;
        meta.lock_iterations = None;
        meta.lock_version = None;
        meta.lock_failures = None;
        meta.links = Vec::new();
        meta.created = self.clock.now();
        meta.modified = self.clock.now();
        // 평문 본문이 `String`이 되는 곳이다. 쓰고 나면 덮는다.
        let document = Wiped(MemoDocument {
            meta,
            body: decrypted.body_str().to_string(),
            unknown_frontmatter_lines: decrypted.unknown_frontmatter_lines.clone(),
            unknown_link_tokens: decrypted.unknown_link_tokens.clone(),
        });
        let steps = self.move_to_plain_steps(id, &new_id, &session, &document.0);
        if let Err(error) = steps {
            let _ = secure_delete::remove(&self.memo_folder(&new_id), None);
            return Err(error);
        }
        let preview = prefix_characters(&document.0.body, PREVIEW_CHARACTER_LIMIT);
        self.update_summary(document.0.meta.clone(), preview);
        self.destroy_memo(id)?;
        Ok(new_id)
    }

    fn move_to_plain_steps(
        &self,
        id: &MemoID,
        new_id: &MemoID,
        session: &MemoLockSession,
        document: &MemoDocument,
    ) -> StoreResult<()> {
        self.repo.save(document)?;
        let to = self.repo.attachments_directory(new_id);
        fs::create_dir_all(&to)?;
        let from = self.repo.attachments_directory(id);
        for path in read_all(&from)? {
            let Some(name) = encrypted_name(&path) else { continue };
            let plain = session.open(&fs::read(&path)?, Some(&name))?;
            atomic_write(&to.join(&name), &plain)?;
            let verified = Zeroizing::new(fs::read(to.join(&name))?);
            if verified.as_slice() != plain.as_slice() {
                return Err(StoreError::Damaged);
            }
        }
        secure_delete::synchronize(&self.memo_folder(new_id))?;
        if self.repo.load(new_id)?.body != document.body {
            return Err(StoreError::Damaged);
        }
        for path in read_all(&from)? {
            let Some(name) = encrypted_name(&path) else { continue };
            let plain = session.open(&fs::read(&path)?, Some(&name))?;
            let moved = Zeroizing::new(fs::read(to.join(&name))?);
            if moved.as_slice() != plain.as_slice() {
                return Err(StoreError::Damaged);
            }
        }
        Ok(())
    }

    /// 열쇠 삭제, 파기 장부 기록, 덮어쓰기 순서를 지킨다. 실패한 삭제는 장부로 다음 동기화에서 재시도한다.
    pub fn destroy_memo(&mut self, id: &MemoID) -> StoreResult<()> {
        self.repo.key_store().delete(&id.raw_value)?;
        self.relock(id);
        self.repo.ledger_insert(id, "destroyed")?;
        let result = self.destroy_after_ledger(id);
        self.fire_privacy_change();
        result
    }

    fn destroy_after_ledger(&mut self, id: &MemoID) -> StoreResult<()> {
        if let Some(hook) = self.before_privacy_removal.as_mut() {
            hook(id)?;
        }
        secure_delete::remove_copies(id, self.repo.root())?;
        self.repo.permanently_delete(id)?;
        self.summaries.retain(|s| s.meta.id != *id);
        let linking: Vec<MemoID> = self
            .summaries
            .iter()
            .filter(|s| s.meta.links.iter().any(|l| l.to == *id))
            .map(|s| s.meta.id.clone())
            .collect();
        for other in linking {
            self.update_meta(&other, |m| m.links.retain(|l| l.to != *id));
        }
        self.board_layout.placements.remove(&id.raw_value);
        self.board_layout.bento_spans.remove(&id.raw_value);
        self.normalize_manual_order();
        self.repo.save_board_layout(&self.board_layout)?;
        self.reload_trash();
        Ok(())
    }
}

/// 폴더의 모든 항목(숨김 포함, Foundation `contentsOfDirectory` 기본값). 폴더가 없으면 오류.
fn read_all(directory: &Path) -> StoreResult<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for entry in fs::read_dir(directory)? {
        paths.push(entry?.path());
    }
    paths.sort();
    Ok(paths)
}

fn file_name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// `<이름>.enc`에서 이름을 꺼낸다. `.enc` 확장자가 없거나 이름이 비면(`.enc` 숨김 파일) None.
fn encrypted_name(path: &Path) -> Option<String> {
    let name = file_name(path);
    name.strip_suffix(".enc").filter(|stem| !stem.is_empty()).map(String::from)
}
