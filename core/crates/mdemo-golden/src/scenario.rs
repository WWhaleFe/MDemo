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

type Res<T> = Result<T, Box<dyn Error>>;

fn text<'a>(op: &'a Value, key: &str, index: usize) -> Res<&'a str> {
    op.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{index}번 연산에 {key}가 없음").into())
}

fn time(op: &Value, key: &str, index: usize) -> Res<MemoDate> {
    let raw = text(op, key, index)?;
    MemoDate::parse(raw).ok_or_else(|| format!("시각을 읽을 수 없음: {raw}").into())
}

pub fn run(file: &Path, data_dir: &Path) -> Res<()> {
    let root: Value = serde_json::from_slice(&fs::read(file)?)?;
    let ops = root.get("ops").and_then(Value::as_array).ok_or("시나리오 형식 오류")?;

    let clock = Arc::new(ManualClock::new(MemoDate(-978_307_200.)));
    let ids = Arc::new(QueuedIds::default());
    let repo = FileMemoRepository::new(data_dir, clock.clone())?;
    let mut store = MemoStore::new(repo, clock.clone(), ids.clone());

    for (n, op) in ops.iter().enumerate() {
        let index = n + 1;
        let name = text(op, "op", index)?;
        let id = |key: &str| -> Res<MemoID> { Ok(MemoID::new(text(op, key, index)?)) };
        if op.get("time").is_some_and(Value::is_string) {
            clock.set(time(op, "time", index)?);
        }
        match name {
            "create" => {
                ids.push(id("id")?);
                store.create_memo(op.get("colorHex").and_then(Value::as_str), op.get("group").and_then(Value::as_str));
            }
            "saveBody" => {
                store.save_body(&id("id")?, text(op, "body", index)?);
            }
            "updateMeta" => {
                let target = id("id")?;
                store.update_meta(&target, |meta| {
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
                store.link(&id("from")?, &id("to")?, kind);
            }
            "moveToTrash" => store.move_to_trash(&[id("id")?]),
            "restore" => store.restore_from_trash(&[id("id")?]),
            "deletePermanently" => store.permanently_delete(&[id("id")?]),
            "emptyTrash" => {
                let now = time(op, "now", index)?;
                clock.set(now);
                store.empty_trash_older_than(op.get("days").and_then(Value::as_i64).unwrap_or(30), now);
            }
            "emptyTrashAll" => store.empty_trash(),
            "addAttachment" => {
                let bytes = b64::decode(text(op, "bytes", index)?).ok_or("base64 오류")?;
                store.repository().save_attachment(&id("id")?, text(op, "name", index)?, &bytes)?;
            }
            "removeAttachment" => {
                store.repository().remove_attachment(&id("id")?, text(op, "name", index)?)?;
            }
            "pruneUnusedAttachments" => {
                let now = time(op, "now", index)?;
                clock.set(now);
                let days = op.get("days").and_then(Value::as_i64).unwrap_or(1);
                store.repository().prune_unused_attachments(MemoDate(now.0 - days as f64 * 86_400.));
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
                store.set_board_placements(&placements);
            }
            "setGroups" => {
                let groups: Vec<String> = op
                    .get("groups")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                    .unwrap_or_default();
                store.repository().save_groups(&groups)?;
            }
            "ledgerInsert" => store.repository().ledger_insert(&id("id")?, text(op, "name", index)?)?,
            "touch" => set_modified_time(&data_dir.join(text(op, "path", index)?), time(op, "time", index)?)?,
            other => return Err(format!("알 수 없는 연산: {other}").into()),
        }
    }
    Ok(())
}
