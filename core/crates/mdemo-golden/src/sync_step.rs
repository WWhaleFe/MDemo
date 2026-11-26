//! 두 구현이 같은 가짜 드라이브 파일을 이어서 사용하는 시험 명령.
use mdemo_core::{
    id::MemoID,
    meta::MemoDate,
    store::{ManualClock, QueuedIds},
};
use mdemo_sync::{fake::FakeDrive, DriveMirrorSync, SyncMode, SyncService};
use std::{fs, path::Path, sync::Arc};
pub fn run(file: &Path, root: &Path) -> mdemo_sync::Result<()> {
    let op: serde_json::Value = serde_json::from_slice(&fs::read(file)?)?;
    let get = |k: &str| op[k].as_str().ok_or_else(|| format!("인자 없음: {k}"));
    let device = get("device")?;
    let dir = root.join(device);
    fs::create_dir_all(&dir)?;
    if op["action"] == "boundaries" {
        let last = MemoDate(123.);
        let values: Vec<_> = [-0.0006, -0.0005, -0.0004, 0., 0.0004, 0.0005, 0.0006]
            .into_iter()
            .map(|delta| {
                let date = MemoDate(last.0 + delta);
                serde_json::json!([
                    mdemo_sync::engine::same_moment(Some(date), Some(last)),
                    mdemo_sync::engine::external_edit(date, Some(last), true),
                    mdemo_sync::engine::external_edit(date, Some(last), false)
                ])
            })
            .collect();
        fs::write(root.join("result.json"), serde_json::to_vec(&values)?)?;
        return Ok(());
    }
    if op["action"] == "export" {
        let n = mdemo_sync::backup::BackupService::new(dir.join("Data"))
            .export_backup(&root.join(get("archive")?))?;
        fs::write(root.join("result.json"), n.to_string())?;
        return Ok(());
    }
    if op["action"] == "import" {
        let n = mdemo_sync::backup::BackupService::new(dir.join("Data")).import_backup(
            &root.join(get("archive")?),
            op["replace"].as_bool().unwrap_or(false),
        )?;
        fs::write(root.join("result.json"), n.to_string())?;
        return Ok(());
    }
    if op["action"] == "state" {
        let state = mdemo_sync::state::SyncState::load(&dir.join("sync-state-google.json"));
        state.try_save(&dir.join("sync-state-google.json"))?;
        return Ok(());
    }
    let mut drive: FakeDrive = fs::read(root.join("drive.json"))
        .ok()
        .map(|b| serde_json::from_slice(&b))
        .transpose()?
        .unwrap_or_default();
    drive.failures = op["failures"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str().map(String::from))
        .collect();
    let mut service = SyncService::new(
        dir.join("Data"),
        dir.join("Mirror"),
        dir.join("sync-state-google.json"),
    );
    service.clock = Arc::new(ManualClock::new(MemoDate(123.)));
    let ids = Arc::new(QueuedIds::default());
    for value in op["ids"].as_array().into_iter().flatten() {
        ids.push(MemoID::new(value.as_str().ok_or("충돌 ID 오류")?));
    }
    service.ids = ids;
    let sync = DriveMirrorSync {
        service,
        state_url: dir.join("drive-state.json"),
    };
    let mode = match op["mode"].as_str() {
        Some("push") => SyncMode::Push,
        Some("pull") => SyncMode::Pull,
        _ => SyncMode::Both,
    };
    let result = sync.sync(&mut drive, mode);
    let expected = op["expectError"].as_bool().unwrap_or(false);
    if result.is_err() != expected {
        return Err(format!("동기화 결과 불일치: {result:?}").into());
    }
    let report = match result {
        Ok(r) => {
            serde_json::json!({"pushed":r.pushed,"pulled":r.pulled,"conflicts":r.conflicts,"deletions":r.deletions,"unreadable":r.unreadable,"lockedLocal":r.locked_local,"removedLocalOnly":r.removed_local_only})
        }
        Err(_) => serde_json::json!({"error":true}),
    };
    fs::write(root.join("result.json"), serde_json::to_vec(&report)?)?;
    fs::write(root.join("drive.json"), serde_json::to_vec(&drive)?)?;
    Ok(())
}
