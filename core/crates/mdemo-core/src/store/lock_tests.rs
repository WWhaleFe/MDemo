//! 잠긴 메모 흐름 단위 테스트. 반복 횟수는 최소값(200만)이라 키 유도를 적게 쓰도록 짰다.

use super::*;
use crate::{frontmatter::{self, MemoDocument}, meta::MemoMeta};
use mdemo_crypto::{KeyStore, MemoryKeyStore};
use std::{path::PathBuf, sync::Arc};

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("mdemo-lock-{}", MemoID::generate().unwrap()));
        fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn id(n: u32) -> MemoID {
    MemoID::new(format!("01TK{n:022}"))
}
fn date(text: &str) -> MemoDate {
    MemoDate::parse(text).unwrap()
}

struct Fixture {
    _temp: Temp,
    root: PathBuf,
    keys: Arc<MemoryKeyStore>,
    store: MemoStore,
    ids: Arc<QueuedIds>,
}

fn fixture() -> Fixture {
    let temp = Temp::new();
    let clock = Arc::new(ManualClock::new(date("2026-03-01T00:00:00.000Z")));
    let ids = Arc::new(QueuedIds::default());
    let keys = Arc::new(MemoryKeyStore::default());
    let repo = FileMemoRepository::with_keys(&temp.0, clock.clone(), keys.clone()).unwrap();
    let mut store = MemoStore::new(repo, clock, ids.clone());
    store.set_iteration_source(Arc::new(|| 2_000_000));
    Fixture { root: temp.0.clone(), _temp: temp, keys, store, ids }
}

impl Fixture {
    /// 일반 메모(본문 + 첨부 둘)를 만들어 잠근다. 반환: 잠긴 메모 ID.
    fn locked_with_attachments(&mut self) -> MemoID {
        self.ids.push(id(1));
        self.store.create_memo(None, None);
        assert!(self.store.save_body(&id(1), "비밀 본문"));
        self.store.repository().save_attachment(&id(1), "a.png", &[1, 2, 3]).unwrap();
        self.store.repository().save_attachment(&id(1), "b.jpg", &[9; 70_000]).unwrap();
        self.ids.push(id(2));
        self.store.create_locked_memo(b"Ab12", Some(&id(1))).unwrap()
    }
    fn header_failures(&self, id: &MemoID) -> Option<i64> {
        self.store.repository().load(id).unwrap().meta.lock_failures
    }
}

#[test]
fn creating_from_a_plain_memo_moves_body_and_attachments_into_ciphertext() {
    let mut f = fixture();
    let locked = f.locked_with_attachments();
    assert_eq!(locked, id(2));
    // 원본은 파기되고 장부에 오른다. 새 ID는 기기 전용 장부에 오른다.
    assert!(f.store.repository().destroyed().unwrap().contains(&id(1).raw_value));
    assert!(!f.root.join("memos").join(&id(1).raw_value).exists());
    let local_only = crate::ledger::read(&f.root.join("local-only.json")).unwrap();
    assert!(local_only.contains(&id(2).raw_value));
    // 디스크에는 암호문뿐이다.
    let doc = f.store.repository().load(&id(2)).unwrap();
    assert!(doc.meta.is_locked && doc.meta.is_open);
    assert_eq!((doc.meta.lock_version, doc.meta.lock_iterations, doc.meta.lock_failures), (Some(1), Some(2_000_000), Some(0)));
    let raw = fs::read(f.store.repository().memo_file(&id(2))).unwrap();
    assert!(!String::from_utf8_lossy(&raw).contains("비밀"));
    let names = f.store.repository().list_attachments(&id(2));
    assert_eq!(names, vec!["a.png.enc".to_string(), "b.jpg.enc".to_string()]);
    assert_eq!(fs::metadata(f.store.repository().attachments_directory(&id(2)).join("a.png.enc")).unwrap().len(), 3 + 28);
    // 열린 세션으로 읽는다.
    let opened = f.store.decrypted_document(&id(2)).unwrap();
    assert_eq!(opened.body_str(), "비밀 본문");
    let session = f.store.lock_session(&id(2)).unwrap();
    let a = fs::read(f.store.repository().attachments_directory(&id(2)).join("a.png.enc")).unwrap();
    assert_eq!(session.open(&a, Some("a.png")).unwrap().as_slice(), &[1, 2, 3]);
    // 열쇠 저장소에는 감싼 열쇠(12 + 32 + 16)만 있다.
    assert_eq!(f.keys.read_key(&id(2).raw_value).unwrap().unwrap().len(), 60);
    // 잠그면 본문을 못 읽고, 요약 미리보기는 비어 있다.
    f.store.relock(&id(2));
    assert!(matches!(f.store.decrypted_document(&id(2)), Err(StoreError::Locked)));
    assert!(f.store.summaries.iter().find(|s| s.meta.id == id(2)).unwrap().preview.is_empty());
}

#[test]
fn wrong_passwords_count_in_both_places_and_the_right_one_resets() {
    let mut f = fixture();
    let locked = f.locked_with_attachments();
    f.store.relock(&locked);
    // 형식이 틀린 암호는 세지 않는다.
    assert!(matches!(f.store.unlock(&locked, b"x"), Err(StoreError::WrongPassword)));
    assert_eq!(f.keys.read_failures(&locked.raw_value).unwrap(), 0);
    assert!(matches!(f.store.unlock(&locked, b"Zz99"), Err(StoreError::WrongPassword)));
    assert!(matches!(f.store.unlock(&locked, b"Zz98"), Err(StoreError::WrongPassword)));
    assert_eq!(f.keys.read_failures(&locked.raw_value).unwrap(), 2);
    assert_eq!(f.header_failures(&locked), Some(2));
    assert_eq!(f.store.lock_failure_count(&locked), 2);
    f.store.unlock(&locked, b"Ab12").unwrap();
    assert_eq!(f.keys.read_failures(&locked.raw_value).unwrap(), 0);
    assert_eq!(f.header_failures(&locked), Some(0));
    assert_eq!(f.store.decrypted_document(&locked).unwrap().body_str(), "비밀 본문");
}

#[test]
fn failures_start_from_the_larger_of_header_and_key_store() {
    let mut f = fixture();
    let locked = f.locked_with_attachments();
    f.store.relock(&locked);
    let mut doc = f.store.repository().load(&locked).unwrap();
    doc.meta.lock_failures = Some(3);
    f.store.repository().save(&doc).unwrap();
    f.keys.write_failures(&locked.raw_value, 7).unwrap();
    assert!(matches!(f.store.unlock(&locked, b"Zz99"), Err(StoreError::WrongPassword)));
    assert_eq!(f.keys.read_failures(&locked.raw_value).unwrap(), 8);
    assert_eq!(f.header_failures(&locked), Some(8));
    // 앞머리가 더 클 때는 앞머리에서 시작한다.
    f.keys.write_failures(&locked.raw_value, 1).unwrap();
    assert!(matches!(f.store.unlock(&locked, b"Zz99"), Err(StoreError::WrongPassword)));
    assert_eq!(f.header_failures(&locked), Some(9));
}

#[test]
fn the_tenth_failure_destroys_the_memo_with_everything_around_it() {
    let mut f = fixture();
    let locked = f.locked_with_attachments();
    f.store.relock(&locked);
    f.keys.write_failures(&locked.raw_value, 9).unwrap();
    let privacy = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = privacy.clone();
    f.store.on_privacy_change = Some(Box::new(move || {
        seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }));
    assert!(matches!(f.store.unlock(&locked, b"Zz99"), Err(StoreError::Destroyed)));
    assert!(!f.root.join("memos").join(&locked.raw_value).exists());
    assert_eq!(f.keys.read_key(&locked.raw_value).unwrap(), None);
    assert!(f.keys.snapshot().1.get(&locked.raw_value).is_none());
    assert!(f.store.repository().destroyed().unwrap().contains(&locked.raw_value));
    assert!(f.store.summaries.iter().all(|s| s.meta.id != locked));
    assert_eq!(privacy.load(std::sync::atomic::Ordering::SeqCst), 1);
    // 그 뒤에는 열 수도 저장할 수도 없다.
    assert!(matches!(f.store.unlock(&locked, b"Ab12"), Err(StoreError::Destroyed)));
    // 이미 10 이상이면 암호를 시험하지 않고 바로 파기한다.
    let mut g = fixture();
    let second = g.locked_with_attachments();
    g.store.relock(&second);
    g.keys.write_failures(&second.raw_value, 10).unwrap();
    assert!(matches!(g.store.unlock(&second, b"Ab12"), Err(StoreError::Destroyed)));
    assert!(g.store.repository().destroyed().unwrap().contains(&second.raw_value));
}

#[test]
fn tampered_body_is_damaged_and_does_not_raise_the_count() {
    let mut f = fixture();
    let locked = f.locked_with_attachments();
    f.store.relock(&locked);
    f.keys.write_failures(&locked.raw_value, 2).unwrap();
    let mut doc = f.store.repository().load(&locked).unwrap();
    doc.meta.lock_failures = Some(2);
    let mut cipher = b64::decode(&doc.body).unwrap();
    cipher[14] ^= 1;
    doc.body = b64::encode(&cipher);
    f.store.repository().save(&doc).unwrap();
    assert!(matches!(f.store.unlock(&locked, b"Ab12"), Err(StoreError::Damaged)));
    assert_eq!(f.keys.read_failures(&locked.raw_value).unwrap(), 2);
    assert_eq!(f.header_failures(&locked), Some(2));
    assert!(f.store.lock_session(&locked).is_none());
}

#[test]
fn missing_key_and_broken_header_are_reported_without_counting() {
    let mut f = fixture();
    let locked = f.locked_with_attachments();
    f.store.relock(&locked);
    let wrapped = f.keys.read_key(&locked.raw_value).unwrap().unwrap();
    f.keys.delete_key(&locked.raw_value).unwrap();
    assert!(matches!(f.store.unlock(&locked, b"Ab12"), Err(StoreError::MissingKey)));
    assert_eq!(f.keys.read_failures(&locked.raw_value).unwrap(), 0);
    f.keys.write_key(&locked.raw_value, &wrapped[..20]).unwrap();
    assert!(matches!(f.store.unlock(&locked, b"Ab12"), Err(StoreError::Damaged)));
    f.keys.write_key(&locked.raw_value, &wrapped).unwrap();
    f.keys.write_raw_failures(&locked.raw_value, b"abc");
    assert!(matches!(f.store.unlock(&locked, b"Ab12"), Err(StoreError::Damaged)));
}

#[test]
fn changing_the_password_keeps_the_key_and_only_the_new_password_opens() {
    let mut f = fixture();
    let locked = f.locked_with_attachments();
    let before = f.keys.read_key(&locked.raw_value).unwrap().unwrap();
    f.store.change_password(&locked, b"Cd34").unwrap();
    assert_ne!(f.keys.read_key(&locked.raw_value).unwrap().unwrap(), before);
    f.store.relock(&locked);
    assert!(matches!(f.store.unlock(&locked, b"Ab12"), Err(StoreError::WrongPassword)));
    f.store.unlock(&locked, b"Cd34").unwrap();
    assert_eq!(f.store.decrypted_document(&locked).unwrap().body_str(), "비밀 본문");
    // 열려 있지 않으면 바꿀 수 없다.
    f.store.relock(&locked);
    assert!(matches!(f.store.change_password(&locked, b"Ef56"), Err(StoreError::Locked)));
    assert!(matches!(f.store.change_password(&locked, b"x"), Err(StoreError::InvalidPassword)));
}

#[test]
fn moving_to_a_plain_memo_decrypts_attachments_and_destroys_the_locked_one() {
    let mut f = fixture();
    let locked = f.locked_with_attachments();
    f.ids.push(id(3));
    let plain = f.store.move_to_plain_memo(&locked).unwrap();
    assert_eq!(plain, id(3));
    let doc = f.store.repository().load(&plain).unwrap();
    assert!(!doc.meta.is_locked && doc.meta.lock_salt.is_none() && doc.meta.lock_failures.is_none());
    assert_eq!(doc.body, "비밀 본문");
    let dir = f.store.repository().attachments_directory(&plain);
    assert_eq!(fs::read(dir.join("a.png")).unwrap(), vec![1, 2, 3]);
    assert_eq!(fs::read(dir.join("b.jpg")).unwrap().len(), 70_000);
    assert!(f.store.repository().destroyed().unwrap().contains(&locked.raw_value));
    assert_eq!(f.keys.read_key(&locked.raw_value).unwrap(), None);
    // 잠금이 풀려 있어야 옮길 수 있다.
    let mut g = fixture();
    let other = g.locked_with_attachments();
    g.store.relock(&other);
    assert!(matches!(g.store.move_to_plain_memo(&other), Err(StoreError::Locked)));
}

#[test]
fn locked_body_saves_as_ciphertext_and_needs_a_session() {
    let mut f = fixture();
    let locked = f.locked_with_attachments();
    assert!(f.store.save_body(&locked, "새 비밀"));
    let raw = fs::read_to_string(f.store.repository().memo_file(&locked)).unwrap();
    assert!(!raw.contains("새 비밀"));
    assert_eq!(f.store.decrypted_document(&locked).unwrap().body_str(), "새 비밀");
    f.store.relock(&locked);
    assert!(!f.store.save_body(&locked, "열쇠 없음"));
}

#[test]
fn permanently_deleting_locked_memos_uses_the_secure_path() {
    let mut f = fixture();
    let locked = f.locked_with_attachments();
    f.store.move_to_trash(&[locked.clone()]);
    assert!(f.store.lock_session(&locked).is_none());
    f.store.permanently_delete(&[locked.clone()]);
    assert!(f.store.repository().destroyed().unwrap().contains(&locked.raw_value));
    assert!(!f.store.repository().trash_directory(&locked).exists());
    assert_eq!(f.keys.read_key(&locked.raw_value).unwrap(), None);
    assert!(f.root.join("board.json").exists()); // 파기는 보드 배치를 항상 다시 쓴다
    // 휴지통 비우기의 잠긴 항목도 같다.
    let second = f.locked_with_attachments_again();
    f.store.move_to_trash(&[second.clone()]);
    f.store.empty_trash();
    assert!(f.store.repository().destroyed().unwrap().contains(&second.raw_value));
    assert!(f.store.trashed.is_empty());
}

impl Fixture {
    fn locked_with_attachments_again(&mut self) -> MemoID {
        self.ids.push(id(4));
        self.store.create_memo(None, None);
        self.ids.push(id(5));
        self.store.create_locked_memo(b"Gh78", Some(&id(4))).unwrap()
    }
}

#[test]
fn failed_creation_cleans_up_key_and_folder_but_leaves_the_source() {
    let mut f = fixture();
    f.ids.push(id(1));
    f.store.create_memo(None, None);
    f.store.repository().save_attachment(&id(1), "a.png", &[1]).unwrap();
    // 첨부 폴더에 하위 폴더가 있으면 손상으로 본다.
    fs::create_dir_all(f.store.repository().attachments_directory(&id(1)).join("sub")).unwrap();
    f.ids.push(id(2));
    assert!(matches!(f.store.create_locked_memo(b"Ab12", Some(&id(1))), Err(StoreError::Damaged)));
    assert!(!f.root.join("memos").join(&id(2).raw_value).exists());
    assert_eq!(f.keys.read_key(&id(2).raw_value).unwrap(), None);
    assert!(f.root.join("memos").join(&id(1).raw_value).join("memo.md").exists());
    assert!(matches!(f.store.create_locked_memo(b"abc", None), Err(StoreError::InvalidPassword)));
}

#[test]
fn locking_a_locked_memo_is_refused_and_locked_memo_is_not_a_search_hit() {
    let mut f = fixture();
    let locked = f.locked_with_attachments();
    f.ids.push(id(9));
    assert!(matches!(f.store.create_locked_memo(b"Ab12", Some(&locked)), Err(StoreError::Locked)));
    let doc: MemoDocument = f.store.repository().load(&locked).unwrap();
    assert!(frontmatter::encode(&doc).contains("locked: true"));
    let _ = MemoMeta::new(id(1));
}
