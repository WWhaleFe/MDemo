//! 마크다운 파일이 원본인 저장소 (Swift `FileMemoRepository`, DAT-01).
//!
//! ```text
//! <데이터 폴더>/memos/<ULID>/memo.md
//! <데이터 폴더>/memos/<ULID>/attachments/
//! <데이터 폴더>/trash/<ULID>/
//! ```

use super::{
    atomic_write, b64, modified_time, set_modified_time,
    summary::{prefix_characters, MemoSummary, PREVIEW_CHARACTER_LIMIT},
    secure_delete, visible_entries, Clock, StoreError, StoreResult,
};
use crate::{
    board_layout::BoardLayout,
    frontmatter::{self, trim, MemoDocument},
    groups, id::MemoID, json, ledger,
    meta::MemoDate,
};
use mdemo_crypto::{KeyStore, MemoryKeyStore};
use std::{
    collections::BTreeSet,
    fs,
    io::Read,
    path::{Path, PathBuf},
    sync::Arc,
};

const MEMO_FILE_NAME: &str = "memo.md";
const MEMOS_FOLDER: &str = "memos";
const TRASH_FOLDER: &str = "trash";
/// 목록 미리보기를 만들 때 파일 앞부분만 읽는 크기.
const PREVIEW_READ_LIMIT: usize = 8 * 1024;

pub struct FileMemoRepository {
    root: PathBuf,
    clock: Arc<dyn Clock>,
    keys: Arc<dyn KeyStore>,
}

impl FileMemoRepository {
    /// `memos`와 `trash` 폴더를 만든다. 열쇠 저장소는 빈 메모리 구현이다(시험 · 시나리오용).
    /// 실제 앱은 `with_keys`로 키체인 어댑터를 넘긴다(P7).
    pub fn new(root: impl Into<PathBuf>, clock: Arc<dyn Clock>) -> StoreResult<Self> {
        Self::with_keys(root, clock, Arc::new(MemoryKeyStore::default()))
    }

    pub fn with_keys(root: impl Into<PathBuf>, clock: Arc<dyn Clock>, keys: Arc<dyn KeyStore>) -> StoreResult<Self> {
        let root = root.into();
        fs::create_dir_all(root.join(MEMOS_FOLDER))?;
        fs::create_dir_all(root.join(TRASH_FOLDER))?;
        Ok(Self { root, clock, keys })
    }

    /// 그림자 읽기는 실제 폴더를 만들거나 바꾸지 않는다.
    pub fn read_only(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into(), clock: Arc::new(super::SystemClock), keys: Arc::new(MemoryKeyStore::default()) }
    }

    pub fn key_store(&self) -> &Arc<dyn KeyStore> {
        &self.keys
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    // MARK: - 경로

    fn memos_dir(&self) -> PathBuf {
        self.root.join(MEMOS_FOLDER)
    }
    fn trash_dir(&self) -> PathBuf {
        self.root.join(TRASH_FOLDER)
    }
    pub fn memo_directory(&self, id: &MemoID) -> PathBuf {
        self.memos_dir().join(&id.raw_value)
    }
    pub fn memo_file(&self, id: &MemoID) -> PathBuf {
        self.memo_directory(id).join(MEMO_FILE_NAME)
    }
    pub fn trash_directory(&self, id: &MemoID) -> PathBuf {
        self.trash_dir().join(&id.raw_value)
    }
    pub fn attachments_directory(&self, id: &MemoID) -> PathBuf {
        self.memo_directory(id).join(super::attachments::FOLDER_NAME)
    }

    /// 파기 장부. 읽지 못하면 오류다 (Swift `try MemoPrivacyLedger.read`).
    pub fn destroyed(&self) -> StoreResult<BTreeSet<String>> {
        Ok(ledger::read(&self.root.join("destroyed.json"))?)
    }

    // MARK: - 읽기

    pub fn load_summaries(&self) -> StoreResult<Vec<MemoSummary>> {
        let destroyed = self.destroyed()?;
        let entries = visible_entries(&self.memos_dir()).unwrap_or_default();
        let mut summaries = Vec::new();
        for (name, _) in entries {
            let id = MemoID::new(name);
            if !id.is_valid() || destroyed.contains(&id.raw_value) {
                continue;
            }
            // 파일 하나가 깨져도 나머지 메모는 열려야 한다.
            if let Ok(summary) = self.load_summary(&id) {
                summaries.push(summary);
            }
        }
        // 수정 시각이 같으면 Swift는 읽은 순서에 맡긴다. 여기서는 이름순을 유지한다.
        summaries.sort_by(|a, b| b.meta.modified.partial_cmp(&a.meta.modified).unwrap_or(std::cmp::Ordering::Equal));
        Ok(summaries)
    }

    /// 파일 앞부분만 읽어 요약을 만든다.
    fn load_summary(&self, id: &MemoID) -> StoreResult<MemoSummary> {
        let head = read_head(&self.memo_file(id), PREVIEW_READ_LIMIT)?;
        let document = decode(&head)?;
        Ok(MemoSummary::new(
            document.meta,
            prefix_characters(&document.body, PREVIEW_CHARACTER_LIMIT),
        ))
    }

    pub fn load(&self, id: &MemoID) -> StoreResult<MemoDocument> {
        if self.destroyed()?.contains(&id.raw_value) {
            return Err(StoreError::Destroyed);
        }
        let text = fs::read_to_string(self.memo_file(id))?;
        let document = decode(&text)?;
        if document.meta.id != *id {
            return Err(StoreError::Damaged);
        }
        Ok(document)
    }

    // MARK: - 쓰기

    /// 임시 파일에 쓰고 교체하는 방식으로 저장한다 (DAT-08).
    ///
    /// Swift처럼 폴더부터 만든 뒤 파기 여부를 본다. 그래서 파기된 ID를 저장하려 하면
    /// 오류가 나지만 빈 `memos/<ID>` 폴더는 남는다.
    pub fn save(&self, document: &MemoDocument) -> StoreResult<()> {
        let directory = self.memo_directory(&document.meta.id);
        fs::create_dir_all(&directory)?;
        if self.destroyed()?.contains(&document.meta.id.raw_value) {
            return Err(StoreError::Destroyed);
        }
        if document.meta.is_locked {
            let sealed = b64::decode(&document.body).is_some_and(|c| c.len() >= 28)
                && document.meta.lock_version == Some(1)
                && document.meta.lock_salt.is_some();
            if !sealed {
                return Err(StoreError::Locked);
            }
            // 잠긴 메모 폴더는 백업에서 뺀다. 실패하면 저장도 실패한다(Swift `setResourceValues`의 `try`).
            exclude_from_backup(&directory)?;
        }
        atomic_write(&self.memo_file(&document.meta.id), frontmatter::encode(document).as_bytes())?;
        Ok(())
    }

    /// 폴더를 복제하고 새 문서를 저장한다. 저장 실패 시 사본을 지운다.
    pub fn duplicate(&self, id: &MemoID, document: &MemoDocument) -> StoreResult<()> {
        if self.load(id)?.meta.is_locked || document.meta.is_locked { return Err(StoreError::Locked); }
        let destination = self.memo_directory(&document.meta.id);
        fn copy(source: &Path, destination: &Path) -> std::io::Result<()> {
            fs::create_dir(destination)?;
            for entry in fs::read_dir(source)? {
                let entry = entry?;
                let target = destination.join(entry.file_name());
                if entry.file_type()?.is_dir() { copy(&entry.path(), &target)?; }
                else { fs::copy(entry.path(), target)?; }
            }
            Ok(())
        }
        copy(&self.memo_directory(id), &destination)?;
        if let Err(error) = self.save(document) { let _ = fs::remove_dir_all(destination); return Err(error); }
        Ok(())
    }

    // MARK: - 삭제

    /// 휴지통으로 옮긴다 (TRS-01). 첨부 폴더까지 통째로 따라가고 버린 시각을 폴더 수정 시각으로 남긴다 (TRS-03).
    pub fn move_to_trash(&self, id: &MemoID) -> StoreResult<()> {
        let source = self.memo_directory(id);
        if !source.exists() {
            return Ok(());
        }
        let destination = self.trash_directory(id);
        if destination.exists() {
            fs::remove_dir_all(&destination)?;
        }
        fs::rename(&source, &destination)?;
        // 옮기기만 하면 수정 시각은 마지막으로 고친 때 그대로다. 실패해도 넘어간다.
        let _ = set_modified_time(&destination, self.clock.now());
        Ok(())
    }

    /// 휴지통 목록. 버린 시각은 폴더 수정 시각이다.
    pub fn load_trash_summaries(&self) -> StoreResult<Vec<MemoSummary>> {
        let destroyed = self.destroyed()?;
        let entries = visible_entries(&self.trash_dir()).unwrap_or_default();
        let mut summaries = Vec::new();
        for (name, path) in entries {
            let id = MemoID::new(name);
            if !id.is_valid() || destroyed.contains(&id.raw_value) {
                continue;
            }
            let Ok(head) = read_head(&path.join(MEMO_FILE_NAME), PREVIEW_READ_LIMIT) else { continue };
            let Ok(document) = decode(&head) else { continue };
            let mut summary = MemoSummary::new(
                document.meta,
                prefix_characters(&document.body, PREVIEW_CHARACTER_LIMIT),
            );
            summary.deleted_at = modified_time(&path).ok();
            summaries.push(summary);
        }
        // 값이 없으면 가장 오래된 것으로 본다(Swift `distantPast`).
        let key = |s: &MemoSummary| s.deleted_at.map_or(f64::NEG_INFINITY, |d| d.0);
        summaries.sort_by(|a, b| key(b).partial_cmp(&key(a)).unwrap_or(std::cmp::Ordering::Equal));
        Ok(summaries)
    }

    pub fn restore_from_trash(&self, id: &MemoID) -> StoreResult<()> {
        if self.destroyed()?.contains(&id.raw_value) {
            return Err(StoreError::Destroyed);
        }
        let source = self.trash_directory(id);
        if !source.exists() {
            return Ok(());
        }
        let destination = self.memo_directory(id);
        if destination.exists() {
            // 같은 ID가 이미 있으면 되돌리지 않는다. 덮어써서 잃는 것보다 남기는 편이 낫다.
            return Ok(());
        }
        fs::rename(&source, &destination)?;
        Ok(())
    }

    /// 일반 메모의 영구 삭제. 폴더째 지우므로 첨부도 함께 사라진다 (TRS-04, TRS-05).
    ///
    /// 열쇠가 있거나 휴지통 파일을 읽지 못하거나 잠긴 메모이면 열쇠 삭제, 파기 장부 기록,
    /// 안전 삭제 순서로 간다(Swift와 같다). 없는 ID도 이 길을 타서 파기 장부에 들어간다.
    pub fn permanently_delete(&self, id: &MemoID) -> StoreResult<()> {
        let target = self.trash_directory(id);
        let document = fs::read_to_string(target.join(MEMO_FILE_NAME))
            .ok()
            .and_then(|text| frontmatter::decode(&text).ok());
        let has_key = self.keys.read_key(&id.raw_value)?.is_some();
        if has_key || document.as_ref().is_none_or(|d| d.meta.is_locked) {
            self.keys.delete(&id.raw_value)?;
            self.ledger_insert(id, "destroyed")?;
            secure_delete::remove_copies(id, &self.root)?;
        }
        if target.exists() {
            fs::remove_dir_all(&target)?;
        }
        // 휴지통 안의 다른 메모도 복원했을 때 끊어진 연결이 남지 않게 한다 (TRS-04).
        for folder in [MEMOS_FOLDER, TRASH_FOLDER] {
            for (name, entry) in visible_entries(&self.root.join(folder))? {
                if !MemoID::new(name).is_valid() {
                    continue;
                }
                let url = entry.join(MEMO_FILE_NAME);
                let Ok(text) = fs::read_to_string(&url) else { continue };
                let Ok(mut doc) = frontmatter::decode(&text) else { continue };
                if !doc.meta.links.iter().any(|l| l.to == *id) {
                    continue;
                }
                let deleted_at = if folder == TRASH_FOLDER { modified_time(&entry).ok() } else { None };
                doc.meta.links.retain(|l| l.to != *id);
                doc.meta.modified = self.clock.now();
                atomic_write(&url, frontmatter::encode(&doc).as_bytes())?;
                // 연결 정리로 휴지통 보관 기간이 다시 시작되지 않게 한다 (TRS-03).
                if let Some(deleted_at) = deleted_at {
                    set_modified_time(&entry, deleted_at)?;
                }
            }
        }
        Ok(())
    }

    /// 지정한 시각보다 오래 버려진 항목을 비운다. None이면 전부 (TRS-03, TRS-04).
    /// 항목별 오류는 Swift처럼 무시한다.
    pub fn empty_trash(&self, deleted_before: Option<MemoDate>) -> StoreResult<()> {
        for (name, path) in visible_entries(&self.trash_dir()).unwrap_or_default() {
            let id = MemoID::new(name);
            if !id.is_valid() {
                continue;
            }
            if let Some(limit) = deleted_before {
                let deleted_at = modified_time(&path).unwrap_or_else(|_| self.clock.now());
                if !(deleted_at < limit) {
                    continue;
                }
            }
            let _ = self.permanently_delete(&id);
        }
        Ok(())
    }

    // MARK: - 그룹 · 보드

    pub fn load_groups(&self) -> Vec<String> {
        fs::read(self.root.join("groups.json")).map(|d| groups::decode(&d)).unwrap_or_default()
    }

    pub fn save_groups(&self, list: &[String]) -> StoreResult<()> {
        Ok(atomic_write(&self.root.join("groups.json"), &groups::encode(list)?)?)
    }

    pub fn load_board_layout(&self) -> BoardLayout {
        fs::read(self.root.join("board.json"))
            .ok()
            .and_then(|d| serde_json::from_slice(&d).ok())
            .unwrap_or_default()
    }

    pub fn save_board_layout(&self, layout: &BoardLayout) -> StoreResult<()> {
        Ok(atomic_write(&self.root.join("board.json"), &json::encode(layout, true, true)?)?)
    }

    // MARK: - 장부

    /// 장부에 ID를 더한다 (Swift `MemoPrivacyLedger.insert`). `name`은 `destroyed` 또는 `local-only`.
    pub fn ledger_insert(&self, id: &MemoID, name: &str) -> StoreResult<()> {
        let path = self.root.join(format!("{name}.json"));
        let mut ids = ledger::read(&path)?;
        ids.insert(id.raw_value.clone());
        Ok(ledger::write(&path, &ids)?)
    }
}

/// 맥: 폴더에 백업 제외 표시(`com.apple.metadata:com_apple_backup_excludeItem`)를 단다.
/// Foundation의 `isExcludedFromBackup = true`가 쓰는 값(속성 목록 문자열 "com.apple.backupd")을 그대로 쓴다.
#[cfg(target_os = "macos")]
pub fn exclude_from_backup(directory: &Path) -> StoreResult<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    extern "C" {
        fn setxattr(path: *const i8, name: *const i8, value: *const u8, size: usize, position: u32, options: i32) -> i32;
    }
    // bplist00 + 문자열("com.apple.backupd") + 오프셋 표 (Foundation이 쓰는 바이트와 같다)
    const VALUE: [u8; 61] = [
        0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30, 0x5F, 0x10, 0x11, 0x63, 0x6F, 0x6D, 0x2E, 0x61,
        0x70, 0x70, 0x6C, 0x65, 0x2E, 0x62, 0x61, 0x63, 0x6B, 0x75, 0x70, 0x64, 0x08, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1C,
    ];
    // 링크를 따라가지 않는다(Gemini 교차 검수 지적).
    const XATTR_NOFOLLOW: i32 = 0x0001;
    let path = CString::new(directory.as_os_str().as_bytes()).map_err(|_| StoreError::Damaged)?;
    let name = CString::new("com.apple.metadata:com_apple_backup_excludeItem").expect("속성 이름");
    // SAFETY: 두 C 문자열은 호출이 끝날 때까지 살아 있고, 값 버퍼는 길이만큼 유효하다.
    let status = unsafe { setxattr(path.as_ptr().cast(), name.as_ptr().cast(), VALUE.as_ptr(), VALUE.len(), 0, XATTR_NOFOLLOW) };
    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error().into())
    }
}

/// 그 밖의 운영체제에는 이 표시가 없다. Windows 백업 제외는 P8에서 정한다.
#[cfg(not(target_os = "macos"))]
pub fn exclude_from_backup(_directory: &Path) -> StoreResult<()> {
    Ok(())
}

fn decode(text: &str) -> StoreResult<MemoDocument> {
    frontmatter::decode(text).map_err(StoreError::Format)
}

/// 파일 앞부분만 읽는다. 잘린 지점이 UTF-8 문자 중간이면 뒤에서 최대 3바이트를 덜어 내고,
/// 닫는 구분자 `---`가 앞부분에 없으면 파일 전체를 읽는다.
///
/// CRLF 파일은 줄 끝의 CR 때문에 구분자 줄로 세어지지 않아 항상 전체를 읽는다.
/// 덜어 낸 경우에는 구분자를 다시 세지 않고 앞부분만 쓴다 (Swift와 같다).
fn read_head(path: &Path, limit: usize) -> StoreResult<String> {
    let mut data = Vec::new();
    fs::File::open(path)?.take(limit as u64).read_to_end(&mut data)?;
    let mut text = match String::from_utf8(data.clone()) {
        Ok(text) => text,
        Err(_) => {
            for drop in 1..=3 {
                if data.len() > drop {
                    if let Ok(recovered) = std::str::from_utf8(&data[..data.len() - drop]) {
                        return Ok(recovered.to_string());
                    }
                }
            }
            return Err(StoreError::Format("여는 구분자 없음".into()));
        }
    };
    if count_delimiters(&text) < 2 {
        text = fs::read_to_string(path)?;
    }
    Ok(text)
}

fn count_delimiters(text: &str) -> usize {
    text.split('\n').filter(|line| trim(line) == "---").count()
}
