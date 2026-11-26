//! 데이터 폴더 시나리오 실행기 (P3). Swift `mdemo-golden scenario`와 같은 연산 목록을 Rust 저장소로 수행한다.
//! 시각과 ID는 시나리오의 고정값을 주입한다.

use mdemo_core::{
    board_layout::Placement,
    id::MemoID,
    link::MemoLinkKind,
    meta::MemoDate,
    store::{b64, set_modified_time, FileMemoRepository, ManualClock, MemoStore, QueuedIds},
};
use serde_json::Value;
use std::{error::Error, fs, path::Path, sync::Arc};

pub type Res<T> = Result<T, Box<dyn Error>>;

pub fn text<'a>(op: &'a Value, key: &str, index: usize) -> Res<&'a str> {
    op.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{index}번 연산에 {key}가 없음").into())
}

pub fn time(op: &Value, key: &str, index: usize) -> Res<MemoDate> {
    let raw = text(op, key, index)?;
    MemoDate::parse(raw).ok_or_else(|| format!("시각을 읽을 수 없음: {raw}").into())
}

/// 저장소 · MemoStore · 주입 시계를 묶은 실행 환경. `lock` 시나리오도 같은 연산을 재사용한다.
pub struct Context {
    pub clock: Arc<ManualClock>,
    pub ids: Arc<QueuedIds>,
    pub store: MemoStore,
    pub data_dir: std::path::PathBuf,
}

impl Context {
    pub fn new(data_dir: &Path, keys: Arc<dyn mdemo_crypto::KeyStore>) -> Res<Self> {
        let clock = Arc::new(ManualClock::new(MemoDate(-978_307_200.)));
        let ids = Arc::new(QueuedIds::default());
        let repo = FileMemoRepository::with_keys(data_dir, clock.clone(), keys)?;
        let store = MemoStore::new(repo, clock.clone(), ids.clone());
        Ok(Self { clock, ids, store, data_dir: data_dir.to_path_buf() })
    }

    /// 공통 연산 하나를 수행한다. 모르는 연산이면 false.
    pub fn apply(&mut self, op: &Value, index: usize) -> Res<bool> {
        let name = text(op, "op", index)?;
        let id = |key: &str| -> Res<MemoID> { Ok(MemoID::new(text(op, key, index)?)) };
        if op.get("time").is_some_and(Value::is_string) {
            self.clock.set(time(op, "time", index)?);
        }
        match name {
            "create" => {
                self.ids.push(id("id")?);
                self.store.create_memo(op.get("colorHex").and_then(Value::as_str), op.get("group").and_then(Value::as_str));
            }
            "saveBody" => {
                self.store.save_body(&id("id")?, text(op, "body", index)?);
            }
            "updateMeta" => {
                let target = id("id")?;
                self.store.update_meta(&target, |meta| {
                    if let Some(v) = op.get("colorHex").and_then(Value::as_str) {
                        meta.color_hex = v.into();
                    }
                    if let Some(v) = op.get("group") {
                        meta.group = v.as_str().map(String::from);
                    }
                    if let Some(v) = op.get("title") {
                        meta.title = v.as_str().map(String::from);
                    }
                    if let Some(v) = op.get("isOpen").and_then(Value::as_bool) {
                        meta.is_open = v;
                    }
                    if let Some(v) = op.get("isPinned").and_then(Value::as_bool) {
                        meta.is_pinned = v;
                    }
                });
            }
            "link" => {
                let kind: MemoLinkKind = serde_json::from_value(Value::String(text(op, "kind", index)?.into()))
                    .map_err(|_| "알 수 없는 연결 종류")?;
                self.store.link(&id("from")?, &id("to")?, kind);
            }
            "moveToTrash" => self.store.move_to_trash(&[id("id")?]),
            "restore" => self.store.restore_from_trash(&[id("id")?]),
            "deletePermanently" => self.store.permanently_delete(&[id("id")?]),
            "emptyTrash" => {
                let now = time(op, "now", index)?;
                self.clock.set(now);
                self.store.empty_trash_older_than(op.get("days").and_then(Value::as_i64).unwrap_or(30), now);
            }
            "emptyTrashAll" => self.store.empty_trash(),
            "addAttachment" => {
                let bytes = b64::decode(text(op, "bytes", index)?).ok_or("base64 오류")?;
                self.store.repository().save_attachment(&id("id")?, text(op, "name", index)?, &bytes)?;
            }
            "removeAttachment" => {
                self.store.repository().remove_attachment(&id("id")?, text(op, "name", index)?)?;
            }
            "pruneUnusedAttachments" => {
                let now = time(op, "now", index)?;
                self.clock.set(now);
                let days = op.get("days").and_then(Value::as_i64).unwrap_or(1);
                self.store.repository().prune_unused_attachments(MemoDate(now.0 - days as f64 * 86_400.));
            }
            "setBoardPlacements" => {
                let mut placements = Vec::new();
                if let Some(map) = op.get("placements").and_then(Value::as_object) {
                    for (key, value) in map {
                        let x = value.get("x").and_then(Value::as_f64).unwrap_or(0.);
                        let y = value.get("y").and_then(Value::as_f64).unwrap_or(0.);
                        placements.push((MemoID::new(key.as_str()), Placement { x, y }));
                    }
                }
                self.store.set_board_placements(&placements);
            }
            "setGroups" => {
                let groups: Vec<String> = op
                    .get("groups")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                    .unwrap_or_default();
                self.store.repository().save_groups(&groups)?;
            }
            "ledgerInsert" => self.store.repository().ledger_insert(&id("id")?, text(op, "name", index)?)?,
            "touch" => set_modified_time(&self.data_dir.join(text(op, "path", index)?), time(op, "time", index)?)?,
            _ => return Ok(false),
        }
        Ok(true)
    }
}

pub fn run(file: &Path, data_dir: &Path) -> Res<()> {
    let root: Value = serde_json::from_slice(&fs::read(file)?)?;
    let ops = root.get("ops").and_then(Value::as_array).ok_or("시나리오 형식 오류")?;
    let mut context = Context::new(data_dir, Arc::new(mdemo_crypto::MemoryKeyStore::default()))?;
    for (n, op) in ops.iter().enumerate() {
        if !context.apply(op, n + 1)? {
            return Err(format!("알 수 없는 연산: {}", op.get("op").and_then(Value::as_str).unwrap_or("")).into());
        }
    }
    Ok(())
}
