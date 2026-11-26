//! 네트워크 없이 경계, 경쟁 편집, 재시도와 폴더 교체를 검증한다.
use super::*;
use mdemo_core::{
    frontmatter::{self, MemoDocument},
    id::MemoID,
    meta::{MemoDate, MemoMeta},
    store::{modified_time, set_modified_time},
};
use std::{fs, path::PathBuf};
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let p =
            std::env::temp_dir().join(format!("mdemo-sync-test-{}", MemoID::generate().unwrap()));
        fs::create_dir_all(&p).unwrap();
        Self(p)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const ID: &str = "01ARZ3NDEKTSV4RRFFQ69G5F00";
fn put(root: &std::path::Path, body: &str, date: f64) {
    let p = root.join("memos").join(ID);
    fs::create_dir_all(&p).unwrap();
    let mut meta = MemoMeta::new(MemoID::new(ID));
    meta.created = MemoDate(0.);
    meta.modified = MemoDate(date);
    fs::write(
        p.join("memo.md"),
        frontmatter::encode(&MemoDocument {
            meta,
            body: body.into(),
            unknown_frontmatter_lines: Vec::new(),
            unknown_link_tokens: Vec::new(),
        }),
    )
    .unwrap();
}
#[test]
fn 상태_쌍은_정확한_날짜만_채택한다() {
    let t = Temp::new();
    let p = t.0.join("state.json");
    fs::write(&p, b"{\"a\":123,\"b\":123.0000001}").unwrap();
    fs::write(state::hashes_path(&p),b"{\"a\":{\"date\":123,\"hashes\":[\"one\",\"two\"]},\"b\":{\"date\":123,\"hashes\":[\"stale\"]}}").unwrap();
    let s = state::SyncState::load(&p);
    assert_eq!(s.hashes.len(), 1);
    s.try_save(&p).unwrap();
    assert_eq!(state::SyncState::load(&p).hashes["a"], vec!["one", "two"]);
}
#[test]
fn 훑은_뒤_양쪽_변경은_덮어쓰지_않는다() {
    let t = Temp::new();
    let l = t.0.join("local");
    let r = t.0.join("remote");
    put(&l, "local", 123.);
    put(&r, "remote", 124.);
    let mut s = SyncService::new(&l, &r, t.0.join("state.json"));
    let dest = r.clone();
    s.after_scan = Some(Box::new(move || put(&dest, "race", 125.)));
    let report = s.sync(SyncMode::Both).unwrap();
    assert_eq!(report.conflicts, 0);
    assert!(fs::read_to_string(r.join("memos").join(ID).join("memo.md"))
        .unwrap()
        .ends_with("race"));
}
#[test]
fn 변경이_없으면_시각을_보존한다() {
    let t = Temp::new();
    let l = t.0.join("local");
    let r = t.0.join("remote");
    put(&l, "same", 123.);
    let s = SyncService::new(&l, &r, t.0.join("state.json"));
    s.sync(SyncMode::Both).unwrap();
    let path = r.join("memos").join(ID).join("memo.md");
    set_modified_time(&path, MemoDate(12.)).unwrap();
    s.sync(SyncMode::Both).unwrap();
    assert_eq!(modified_time(&path).unwrap(), MemoDate(12.));
}
#[test]
fn 드라이브_실패는_다음_회차에_재시도한다() {
    let t = Temp::new();
    let l = t.0.join("Data");
    put(&l, "memo", 123.);
    let s = DriveMirrorSync {
        service: SyncService::new(&l, t.0.join("Mirror"), t.0.join("state.json")),
        state_url: t.0.join("drive-state.json"),
    };
    let mut api = fake::FakeDrive::default();
    api.failures.insert("upload".into());
    assert!(s.sync(&mut api, SyncMode::Both).is_err());
    assert!(!drive::DriveState::load(&s.state_url).completed_once);
    api.failures.clear();
    s.sync(&mut api, SyncMode::Both).unwrap();
    assert!(drive::DriveState::load(&s.state_url).completed_once);
    assert!(api.paths().contains_key(&format!("memos/{ID}/memo.md")));
}
#[test]
fn 폴더_교체는_오래된_첨부를_남기지_않는다() {
    let t = Temp::new();
    let source = t.0.join("source");
    let dest = t.0.join("dest");
    fs::create_dir_all(&source).unwrap();
    fs::create_dir_all(&dest).unwrap();
    fs::write(source.join("new"), b"new").unwrap();
    fs::write(dest.join("old"), b"old").unwrap();
    files::replace_tree(&source, &dest).unwrap();
    assert!(!dest.join("old").exists());
    assert_eq!(fs::read(dest.join("new")).unwrap(), b"new");
}
#[test]
fn 윈도우_교체_실패는_원본으로_되돌린다() {
    let t = Temp::new();
    let dest = t.0.join("memo");
    fs::create_dir_all(&dest).unwrap();
    fs::write(dest.join("original"), b"keep").unwrap();
    assert!(files::replace_staged_portable(&t.0.join("missing.tmp"), &dest).is_err());
    assert_eq!(fs::read(dest.join("original")).unwrap(), b"keep");
    assert!(!t.0.join(".memo.old").exists());
}
#[test]
fn 윈도우_이전_복구본은_덮어쓰지_않는다() {
    let t = Temp::new();
    let dest = t.0.join("memo");
    let staging = t.0.join(".memo.tmp");
    fs::create_dir_all(&dest).unwrap();
    fs::create_dir_all(&staging).unwrap();
    fs::create_dir_all(t.0.join(".memo.old")).unwrap();
    fs::write(dest.join("original"), b"keep").unwrap();
    assert!(files::replace_staged_portable(&staging, &dest).is_err());
    assert_eq!(fs::read(dest.join("original")).unwrap(), b"keep");
}
#[test]
fn 백업_경로_탈출은_거부한다() {
    use std::io::Write;
    let t = Temp::new();
    let archive = t.0.join("bad.zip");
    let mut zip = zip::ZipWriter::new(fs::File::create(&archive).unwrap());
    zip.start_file("../escape", zip::write::SimpleFileOptions::default())
        .unwrap();
    zip.write_all(b"bad").unwrap();
    zip.finish().unwrap();
    assert!(backup::BackupService::new(t.0.join("Data"))
        .import_backup(&archive, true)
        .is_err());
    assert!(!t.0.join("escape").exists());
}
#[test]
fn update_not_found는_새_upload로_재시도한다() {
    let t = Temp::new();
    let local = t.0.join("Data");
    put(&local, "first", 123.);
    let sync = DriveMirrorSync {
        service: SyncService::new(&local, t.0.join("Mirror"), t.0.join("sync.json")),
        state_url: t.0.join("drive.json"),
    };
    let mut api = fake::FakeDrive::default();
    sync.sync(&mut api, SyncMode::Both).unwrap();
    api.remove_remotely(&format!("memos/{ID}/memo.md"));
    put(&local, "next", 124.);
    let start = api.calls.len();
    sync.sync(&mut api, SyncMode::Push).unwrap();
    assert_eq!(&api.calls[start..], &["update", "upload"]);
    assert!(
        String::from_utf8(api.paths()[&format!("memos/{ID}/memo.md")].clone())
            .unwrap()
            .ends_with("next")
    );
}
#[test]
fn delete_not_found도_성공으로_확정한다() {
    let t = Temp::new();
    let local = t.0.join("Data");
    put(&local, "first", 123.);
    let sync = DriveMirrorSync {
        service: SyncService::new(&local, t.0.join("Mirror"), t.0.join("sync.json")),
        state_url: t.0.join("drive.json"),
    };
    let mut api = fake::FakeDrive::default();
    sync.sync(&mut api, SyncMode::Both).unwrap();
    api.remove_remotely(&format!("memos/{ID}/memo.md"));
    mdemo_core::ledger::write(
        &local.join("destroyed.json"),
        &std::collections::BTreeSet::from([ID.to_string()]),
    )
    .unwrap();
    sync.sync(&mut api, SyncMode::Push).unwrap();
    let state = drive::DriveState::load(&sync.state_url);
    assert!(state.completed_once);
    assert!(!state.files.contains_key(&format!("memos/{ID}/memo.md")));
}
