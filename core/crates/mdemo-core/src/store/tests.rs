//! 저장소 단위 테스트. Swift `MemoCoreTests`의 저장소 사례를 옮겼다. 모든 시험은 임시 폴더에서 한다.

use super::*;
use crate::{
    board_layout::{BoardLayout, Placement},
    device_state::DeviceMemoState,
    frontmatter::{self, MemoDocument},
    link::MemoLinkKind,
    meta::MemoMeta,
};
use std::{path::PathBuf, sync::Arc};

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("mdemo-store-{}", MemoID::generate().unwrap()));
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
    MemoID::new(format!("01TS{n:022}"))
}
fn date(text: &str) -> MemoDate {
    MemoDate::parse(text).unwrap()
}
fn document(id: &MemoID, body: &str, modified: &str) -> MemoDocument {
    let mut meta = MemoMeta::new(id.clone());
    meta.created = date("2026-01-01T00:00:00.000Z");
    meta.modified = date(modified);
    MemoDocument { meta, body: body.into(), unknown_frontmatter_lines: vec![], unknown_link_tokens: vec![] }
}
fn repo(temp: &Temp) -> (FileMemoRepository, Arc<ManualClock>) {
    let clock = Arc::new(ManualClock::new(date("2026-03-01T00:00:00.000Z")));
    (FileMemoRepository::new(&temp.0, clock.clone()).unwrap(), clock)
}
fn store(temp: &Temp) -> (MemoStore, Arc<ManualClock>, Arc<QueuedIds>) {
    let clock = Arc::new(ManualClock::new(date("2026-03-01T00:00:00.000Z")));
    let ids = Arc::new(QueuedIds::default());
    let repository = FileMemoRepository::new(&temp.0, clock.clone()).unwrap();
    (MemoStore::new(repository, clock.clone(), ids.clone()), clock, ids)
}

#[test]
fn saved_memo_is_read_back() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    let doc = document(&id(1), "본문\n둘째 줄", "2026-01-02T03:04:05.500Z");
    repo.save(&doc).unwrap();
    assert_eq!(repo.load(&id(1)).unwrap(), doc);
    assert!(temp.0.join("memos").join(&id(1).raw_value).join("memo.md").is_file());
}

#[test]
fn summaries_preview_and_sort_newest_first() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    repo.save(&document(&id(1), &"가".repeat(500), "2026-01-01T00:00:00.000Z")).unwrap();
    repo.save(&document(&id(2), "둘", "2026-02-01T00:00:00.000Z")).unwrap();
    repo.save(&document(&id(3), "셋", "2026-01-15T00:00:00.000Z")).unwrap();
    let list = repo.load_summaries().unwrap();
    let order: Vec<_> = list.iter().map(|s| s.meta.id.clone()).collect();
    assert_eq!(order, vec![id(2), id(3), id(1)]);
    assert_eq!(list[2].preview.chars().count(), 200);
}

#[test]
fn long_body_is_not_fully_read_but_summary_is_complete() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    // 8KB 경계가 한글(3바이트) 한가운데에 걸리도록 본문을 길게 쓴다.
    repo.save(&document(&id(1), &"한".repeat(10_000), "2026-01-01T00:00:00.000Z")).unwrap();
    let summary = &repo.load_summaries().unwrap()[0];
    assert_eq!(summary.preview, "한".repeat(200));
}

#[test]
fn crlf_file_is_read_in_full() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    repo.save(&document(&id(1), "x", "2026-01-01T00:00:00.000Z")).unwrap();
    // 앞머리가 8KB를 넘는 CRLF 파일: 구분자 줄이 CR 때문에 세어지지 않아 전체를 읽는다.
    let mut text = fs::read_to_string(repo.memo_file(&id(1))).unwrap();
    text = text.replacen("---\n", "---\n", 1);
    let padding = "unknownKey: ".to_string() + &"a".repeat(9000) + "\n";
    text = text.replacen("\n---\n", &format!("\n{padding}---\n"), 1).replace('\n', "\r\n");
    fs::write(repo.memo_file(&id(1)), text).unwrap();
    assert_eq!(repo.load_summaries().unwrap().len(), 1);
}

#[test]
fn head_without_closing_delimiter_falls_back_to_full_read() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    let mut doc = document(&id(1), "본문", "2026-01-01T00:00:00.000Z");
    doc.unknown_frontmatter_lines = vec![format!("memo: {}", "a".repeat(9000))];
    repo.save(&doc).unwrap();
    let summary = &repo.load_summaries().unwrap()[0];
    assert_eq!(summary.preview, "본문");
}

#[test]
fn overwrite_leaves_no_old_content_or_temp_files() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    repo.save(&document(&id(1), &"옛".repeat(100), "2026-01-01T00:00:00.000Z")).unwrap();
    repo.save(&document(&id(1), "새", "2026-01-02T00:00:00.000Z")).unwrap();
    assert_eq!(repo.load(&id(1)).unwrap().body, "새");
    let names: Vec<_> = fs::read_dir(repo.memo_directory(&id(1))).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(names.len(), 1);
}

#[test]
fn trash_moves_attachments_and_stamps_folder_time() {
    let temp = Temp::new();
    let (repo, clock) = repo(&temp);
    repo.save(&document(&id(1), "본문", "2020-01-01T00:00:00.000Z")).unwrap();
    repo.save_attachment(&id(1), "a.png", b"png").unwrap();
    clock.set(date("2026-03-05T00:00:00.000Z"));
    repo.move_to_trash(&id(1)).unwrap();
    assert!(!repo.memo_directory(&id(1)).exists());
    assert!(repo.trash_directory(&id(1)).join("attachments/a.png").is_file());
    // 오래 묵은 메모도 버린 시각으로 보관 기간을 센다 (TRS-03).
    let trash = repo.load_trash_summaries().unwrap();
    assert_eq!(trash[0].deleted_at, Some(date("2026-03-05T00:00:00.000Z")));
    assert!(repo.load_summaries().unwrap().is_empty());
}

#[test]
fn restore_returns_memo_and_refuses_to_overwrite() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    repo.save(&document(&id(1), "원본", "2026-01-01T00:00:00.000Z")).unwrap();
    repo.move_to_trash(&id(1)).unwrap();
    repo.restore_from_trash(&id(1)).unwrap();
    assert_eq!(repo.load(&id(1)).unwrap().body, "원본");
    // 같은 ID가 이미 있으면 되돌리지 않고 휴지통에 남긴다.
    repo.move_to_trash(&id(1)).unwrap();
    repo.save(&document(&id(1), "새로 만듦", "2026-01-02T00:00:00.000Z")).unwrap();
    repo.restore_from_trash(&id(1)).unwrap();
    assert_eq!(repo.load(&id(1)).unwrap().body, "새로 만듦");
    assert!(repo.trash_directory(&id(1)).exists());
}

#[test]
fn broken_file_does_not_block_the_list() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    repo.save(&document(&id(1), "멀쩡", "2026-01-01T00:00:00.000Z")).unwrap();
    repo.save(&document(&id(2), "깨질 것", "2026-01-02T00:00:00.000Z")).unwrap();
    fs::write(repo.memo_file(&id(2)), "앞머리가 없다").unwrap();
    fs::create_dir_all(temp.0.join("memos/not-an-id")).unwrap();
    let list = repo.load_summaries().unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].meta.id, id(1));
}

#[test]
fn load_rejects_mismatched_id_and_destroyed() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    repo.save(&document(&id(1), "a", "2026-01-01T00:00:00.000Z")).unwrap();
    fs::rename(repo.memo_directory(&id(1)), repo.memo_directory(&id(2))).unwrap();
    assert!(matches!(repo.load(&id(2)), Err(StoreError::Damaged)));
    repo.ledger_insert(&id(2), "destroyed").unwrap();
    assert!(matches!(repo.load(&id(2)), Err(StoreError::Destroyed)));
    assert!(repo.load_summaries().unwrap().is_empty());
}

#[test]
fn saving_destroyed_id_fails_but_leaves_empty_folder() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    repo.ledger_insert(&id(1), "destroyed").unwrap();
    assert!(matches!(repo.save(&document(&id(1), "a", "2026-01-01T00:00:00.000Z")), Err(StoreError::Destroyed)));
    assert!(repo.memo_directory(&id(1)).is_dir());
    assert!(!repo.memo_file(&id(1)).exists());
}

#[test]
fn locked_memo_save_checks_shape_and_permanent_delete_takes_the_secure_path() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    let mut doc = document(&id(1), "not base64", "2026-01-01T00:00:00.000Z");
    doc.meta.is_locked = true;
    assert!(matches!(repo.save(&doc), Err(StoreError::Locked)));
    doc.body = b64::encode(&[7u8; 40]);
    doc.meta.lock_version = Some(1);
    doc.meta.lock_salt = Some("salt".into());
    repo.save(&doc).unwrap();
    assert_eq!(repo.load(&id(1)).unwrap(), doc);
    // 잠긴 메모(또는 읽을 수 없는 메모)의 영구 삭제는 파기 장부에 적고 안전 삭제한다.
    repo.move_to_trash(&id(1)).unwrap();
    repo.permanently_delete(&id(1)).unwrap();
    assert!(!repo.trash_directory(&id(1)).exists());
    assert!(repo.destroyed().unwrap().contains(&id(1).raw_value));
    // 없는 ID도 같은 길로 가서 장부에 들어간다 (Swift와 같다).
    repo.permanently_delete(&id(2)).unwrap();
    assert!(repo.destroyed().unwrap().contains(&id(2).raw_value));
}

#[test]
fn permanent_delete_removes_folder_and_cleans_links_keeping_trash_age() {
    let temp = Temp::new();
    let (repo, clock) = repo(&temp);
    let mut live = document(&id(2), "살아 있음", "2026-01-01T00:00:00.000Z");
    live.meta.links.push(crate::link::MemoLink::new(id(1), MemoLinkKind::Flow, ""));
    let mut trashed = document(&id(3), "휴지통", "2026-01-01T00:00:00.000Z");
    trashed.meta.links.push(crate::link::MemoLink::new(id(1), MemoLinkKind::Line, ""));
    for d in [document(&id(1), "지울 것", "2026-01-01T00:00:00.000Z"), live, trashed] {
        repo.save(&d).unwrap();
    }
    repo.save_attachment(&id(1), "a.png", b"x").unwrap();
    clock.set(date("2026-04-01T00:00:00.000Z"));
    repo.move_to_trash(&id(1)).unwrap();
    repo.move_to_trash(&id(3)).unwrap();
    clock.set(date("2026-05-01T00:00:00.000Z"));
    repo.permanently_delete(&id(1)).unwrap();
    assert!(!repo.trash_directory(&id(1)).exists());
    assert!(repo.load(&id(2)).unwrap().meta.links.is_empty());
    assert_eq!(repo.load(&id(2)).unwrap().meta.modified, date("2026-05-01T00:00:00.000Z"));
    let trash = repo.load_trash_summaries().unwrap();
    assert!(trash[0].meta.links.is_empty());
    // 연결 정리로 보관 기간이 다시 시작되지 않는다 (TRS-03).
    assert_eq!(trash[0].deleted_at, Some(date("2026-04-01T00:00:00.000Z")));
}

#[test]
fn empty_trash_removes_only_expired_items() {
    let temp = Temp::new();
    let (repo, clock) = repo(&temp);
    for n in [1, 2] {
        repo.save(&document(&id(n), "a", "2026-01-01T00:00:00.000Z")).unwrap();
    }
    clock.set(date("2026-04-01T00:00:00.000Z"));
    repo.move_to_trash(&id(1)).unwrap();
    clock.set(date("2026-05-10T00:00:00.000Z"));
    repo.move_to_trash(&id(2)).unwrap();
    repo.empty_trash(Some(date("2026-04-15T00:00:00.000Z"))).unwrap();
    assert!(!repo.trash_directory(&id(1)).exists());
    assert!(repo.trash_directory(&id(2)).exists());
    repo.empty_trash(None).unwrap();
    assert!(!repo.trash_directory(&id(2)).exists());
}

#[test]
fn unused_old_attachments_only_are_pruned() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    repo.save(&document(&id(1), "![](attachments/keep.png)", "2026-01-01T00:00:00.000Z")).unwrap();
    for name in ["keep.png", "drop.png", "new.png"] {
        repo.save_attachment(&id(1), name, b"x").unwrap();
    }
    let dir = repo.attachments_directory(&id(1));
    set_modified_time(&dir.join("keep.png"), date("2026-01-01T00:00:00.000Z")).unwrap();
    set_modified_time(&dir.join("drop.png"), date("2026-01-01T00:00:00.000Z")).unwrap();
    set_modified_time(&dir.join("new.png"), date("2026-03-01T00:00:00.000Z")).unwrap();
    assert_eq!(repo.prune_unused_attachments(date("2026-02-01T00:00:00.000Z")), 1);
    assert_eq!(repo.list_attachments(&id(1)), vec!["keep.png", "new.png"]);
    assert!(repo.save_attachment(&id(1), "../escape.png", b"x").is_err());
    assert!(repo.remove_attachment(&id(1), "new.png").unwrap());
    assert!(!repo.remove_attachment(&id(1), "new.png").unwrap());
}

#[test]
fn groups_board_and_ledgers_persist() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    assert!(repo.load_groups().is_empty());
    repo.save_groups(&["b".into(), "a".into()]).unwrap();
    assert_eq!(repo.load_groups(), vec!["b", "a"]);
    let mut layout = BoardLayout::default();
    layout.placements.insert(id(1).raw_value, Placement { x: 1.5, y: 2. });
    layout.manual_order = vec![id(1)];
    repo.save_board_layout(&layout).unwrap();
    assert_eq!(repo.load_board_layout(), layout);
    // 깨진 파일은 빈 값으로 읽힌다.
    fs::write(temp.0.join("board.json"), "{깨짐").unwrap();
    assert_eq!(repo.load_board_layout(), BoardLayout::default());
    repo.ledger_insert(&id(2), "local-only").unwrap();
    repo.ledger_insert(&id(1), "local-only").unwrap();
    assert_eq!(fs::read_to_string(temp.0.join("local-only.json")).unwrap(), format!("[\"{}\",\"{}\"]", id(1), id(2)));
}

#[test]
fn device_state_is_saved_separately_and_read_again() {
    let temp = Temp::new();
    let path = temp.0.join("sub/device-state.json");
    let mut states = DeviceStateStore::new(&path);
    let state = DeviceMemoState { frame: vec![1., 2., 3., 4.], display_id: Some("d".into()), is_collapsed: true };
    states.set_state(state.clone(), &id(1));
    states.set_state(state.clone(), &id(2));
    states.remove_state(&id(2));
    states.flush();
    let again = DeviceStateStore::new(&path);
    assert_eq!(again.state(&id(1)), Some(&state));
    assert!(again.state(&id(2)).is_none());
    fs::write(&path, "깨짐").unwrap();
    assert!(DeviceStateStore::new(&path).state(&id(1)).is_none());
}

#[test]
fn store_save_body_and_update_meta_skip_unchanged_writes() {
    let temp = Temp::new();
    let (mut store, clock, ids) = store(&temp);
    ids.push(id(1));
    let meta = store.create_memo(None, None);
    clock.set(date("2026-03-02T00:00:00.000Z"));
    assert!(store.save_body(&meta.id, "안녕"));
    let file = store.repository().memo_file(&meta.id);
    set_modified_time(&file, date("2020-01-01T00:00:00.000Z")).unwrap();
    clock.set(date("2026-03-03T00:00:00.000Z"));
    assert!(store.save_body(&meta.id, "안녕"));
    store.update_meta(&meta.id, |m| m.is_open = true);
    assert_eq!(modified_time(&file).unwrap(), date("2020-01-01T00:00:00.000Z"));
    assert_eq!(store.load_document(&meta.id).unwrap().meta.modified, date("2026-03-02T00:00:00.000Z"));
    store.update_meta(&meta.id, |m| m.is_open = false);
    assert_eq!(store.load_document(&meta.id).unwrap().meta.modified, date("2026-03-03T00:00:00.000Z"));
    assert_eq!(store.summaries[0].preview, "안녕");
}

#[test]
fn store_trash_flow_updates_board_order_and_links() {
    let temp = Temp::new();
    let (mut store, clock, ids) = store(&temp);
    ids.push(id(1));
    ids.push(id(2));
    let a = store.create_memo(None, None).id;
    let b = store.create_memo(None, Some("업무")).id;
    store.link(&a, &b, MemoLinkKind::Flow);
    store.link(&b, &a, MemoLinkKind::Related);
    // 한 쌍에는 연결 하나만 남는다.
    assert!(store.load_document(&a).unwrap().meta.links.is_empty());
    assert_eq!(store.load_document(&b).unwrap().meta.links.len(), 1);
    assert_eq!(store.board_layout.manual_order, vec![b.clone(), a.clone()]);
    clock.set(date("2026-03-09T00:00:00.000Z"));
    store.move_to_trash(&[a.clone()]);
    assert_eq!(store.trashed.len(), 1);
    assert_eq!(store.board_layout.manual_order, vec![b.clone()]);
    store.permanently_delete(&[a.clone()]);
    assert!(store.trashed.is_empty());
    assert!(store.load_document(&b).unwrap().meta.links.is_empty());
    clock.set(date("2026-04-09T00:00:00.000Z"));
    store.move_to_trash(&[b.clone()]);
    store.empty_trash_older_than(30, date("2026-04-20T00:00:00.000Z"));
    assert_eq!(store.trashed.len(), 1);
    store.empty_trash_older_than(30, date("2026-05-20T00:00:00.000Z"));
    assert!(store.trashed.is_empty());
}

fn summary(body: &str, title: Option<&str>, group: Option<&str>) -> MemoSummary {
    let mut meta = MemoMeta::new(id(1));
    meta.title = title.map(String::from);
    meta.group = group.map(String::from);
    MemoSummary::new(meta, body.into())
}

#[test]
fn search_matches_title_preview_and_group_case_insensitively() {
    let s = summary("Hello World\n본문", None, Some("업무"));
    assert!(search::matches(&s, "hello"));
    assert!(search::matches(&s, "  world  "));
    assert!(search::matches(&s, "업무"));
    assert!(search::matches(&s, ""));
    assert!(search::matches(&s, "   "));
    assert!(!search::matches(&s, "없는말"));
    // 직접 붙인 제목은 제목으로 걸리고, 본문 첫 줄은 제목이 아니어도 미리보기로 걸린다.
    let titled = summary("본문", Some("회의록"), None);
    assert_eq!(titled.title(), "회의록");
    assert!(search::matches(&titled, "회의"));
}

#[test]
fn search_respects_unicode_equivalence_and_character_boundaries() {
    assert!(search::localized_case_insensitive_contains("Caf\u{e9}", "cafe\u{301}"));
    assert!(!search::localized_case_insensitive_contains("Caf\u{e9}", "cafe"));
    assert!(search::localized_case_insensitive_contains("한글 메모", "한글"));
    assert!(!search::localized_case_insensitive_contains("한글", "하"));
    assert!(search::localized_case_insensitive_contains("ÀBC", "àbc"));
}

#[test]
fn title_skips_image_lines_and_markdown_marks() {
    assert_eq!(summary("![](attachments/a.png)\n## 진짜 제목 ##\n둘째", None, None).title(), "진짜 제목");
    assert_eq!(summary("   \n\n", None, None).title(), "제목 없는 메모");
    assert_eq!(summary("본문", Some("   "), None).title(), "본문");
}

#[test]
fn search_bodies_reads_body_only_and_includes_trash() {
    let temp = Temp::new();
    let (repo, _) = repo(&temp);
    let mut colored = document(&id(1), "찾을 낱말이 든 본문", "2026-01-01T00:00:00.000Z");
    colored.meta.color_hex = "#FFD1DC".into();
    repo.save(&colored).unwrap();
    repo.save(&document(&id(2), "다른 내용", "2026-01-01T00:00:00.000Z")).unwrap();
    repo.save(&document(&id(3), "휴지통의 낱말", "2026-01-01T00:00:00.000Z")).unwrap();
    repo.move_to_trash(&id(3)).unwrap();
    let all = [id(1), id(2), id(3), id(4)];
    let found = repo.search_bodies("낱말", &all);
    assert_eq!(found.len(), 2);
    assert!(found.contains(&id(1)) && found.contains(&id(3)));
    // 프론트매터의 낱말(color, pinned 등)은 본문이 아니다.
    assert!(repo.search_bodies("pinned", &all).is_empty());
    assert!(repo.search_bodies("FFD1DC", &all).is_empty());
    assert!(repo.search_bodies("   ", &all).is_empty());
}
