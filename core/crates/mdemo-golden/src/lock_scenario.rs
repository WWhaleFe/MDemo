//! 암호 메모 시나리오 실행기 (P4). Swift `mdemo-golden lock`과 같은 연산 목록을 Rust 구현으로 수행한다.
//! 데이터 폴더의 `keychain.json`이 열쇠 저장소 상태다(시험용 가짜, 실제 키체인에는 닿지 않는다).
//! Swift 실행기와 같은 형식이라 서로의 결과를 이어 받는다.

use crate::scenario::{text, time, Context, Res};
use mdemo_core::{
    id::MemoID,
    store::{b64, StoreError},
};
use mdemo_crypto::{KeyStore, LockError, MemoryKeyStore};
use serde_json::Value;
use std::{collections::BTreeMap, fs, path::Path, path::PathBuf, sync::Arc};

/// 메모리 열쇠 저장소에 `keychain.json` 내보내기를 붙인 것. 변경이 있을 때마다 내보낸다.
pub struct FileKeyStore {
    inner: MemoryKeyStore,
    path: PathBuf,
}

type Table = BTreeMap<String, BTreeMap<String, String>>;

impl FileKeyStore {
    pub fn open(path: PathBuf) -> Res<Self> {
        let mut keys = BTreeMap::new();
        let mut failures = BTreeMap::new();
        if path.exists() {
            let table: Table = serde_json::from_slice(&fs::read(&path)?)?;
            for (id, text) in table.get("keys").into_iter().flatten() {
                keys.insert(id.clone(), b64::decode(text).ok_or("keychain.json 열쇠 형식 오류")?);
            }
            for (id, text) in table.get("failures").into_iter().flatten() {
                failures.insert(id.clone(), text.clone().into_bytes());
            }
        }
        Ok(Self { inner: MemoryKeyStore::from_parts(keys, failures), path })
    }

    pub fn save(&self) -> Result<(), LockError> {
        let (keys, failures) = self.inner.snapshot();
        let mut table = Table::new();
        table.insert("keys".into(), keys.iter().map(|(k, v)| (k.clone(), b64::encode(v))).collect());
        table.insert(
            "failures".into(),
            failures.iter().map(|(k, v)| (k.clone(), String::from_utf8_lossy(v).into_owned())).collect(),
        );
        let bytes = serde_json::to_vec_pretty(&table).map_err(|e| LockError::KeyStore(e.to_string()))?;
        fs::write(&self.path, bytes).map_err(|e| LockError::KeyStore(e.to_string()))
    }

    fn write_raw_failures(&self, id: &str, raw: &str) -> Result<(), LockError> {
        self.inner.write_raw_failures(id, raw.as_bytes());
        self.save()
    }
}

impl KeyStore for FileKeyStore {
    fn read_key(&self, id: &str) -> Result<Option<Vec<u8>>, LockError> {
        self.inner.read_key(id)
    }
    fn write_key(&self, id: &str, wrapped: &[u8]) -> Result<(), LockError> {
        self.inner.write_key(id, wrapped)?;
        self.save()
    }
    fn delete_key(&self, id: &str) -> Result<(), LockError> {
        self.inner.delete_key(id)?;
        self.save()
    }
    fn read_failures(&self, id: &str) -> Result<i64, LockError> {
        self.inner.read_failures(id)
    }
    fn write_failures(&self, id: &str, failures: i64) -> Result<(), LockError> {
        self.inner.write_failures(id, failures)?;
        self.save()
    }
    fn delete_failures(&self, id: &str) -> Result<(), LockError> {
        self.inner.delete_failures(id)?;
        self.save()
    }
}

/// Swift 실행기와 같은 이름의 오류 종류.
fn kind(error: &StoreError) -> &'static str {
    match error {
        StoreError::InvalidPassword => "invalidPassword",
        StoreError::MissingKey => "missingKey",
        StoreError::WrongPassword => "wrongPassword",
        StoreError::Damaged => "damaged",
        StoreError::Locked => "locked",
        StoreError::Destroyed => "destroyed",
        StoreError::KeyStore(_) => "keyStore",
        StoreError::Authentication => "authentication",
        StoreError::IncorrectSize => "incorrectSize",
        _ => "other",
    }
}

pub fn run(file: &Path, data_dir: &Path, phase: Option<i64>) -> Res<()> {
    let root: Value = serde_json::from_slice(&fs::read(file)?)?;
    let ops = root.get("ops").and_then(Value::as_array).ok_or("시나리오 형식 오류")?;
    fs::create_dir_all(data_dir)?;
    let keys = Arc::new(FileKeyStore::open(data_dir.join("keychain.json"))?);
    let mut ctx = Context::new(data_dir, keys.clone())?;
    ctx.store.set_iteration_source(Arc::new(|| 2_000_000));
    let result = run_ops(&mut ctx, &keys, ops, phase);
    let _ = keys.save();
    result
}

fn run_ops(ctx: &mut Context, keys: &Arc<FileKeyStore>, ops: &[Value], phase: Option<i64>) -> Res<()> {
    for (n, op) in ops.iter().enumerate() {
        let index = n + 1;
        if phase.is_some_and(|p| op.get("phase").and_then(Value::as_i64).unwrap_or(1) != p) {
            continue;
        }
        let name = text(op, "op", index)?;
        let id = |key: &str| -> Res<MemoID> { Ok(MemoID::new(text(op, key, index)?)) };
        if op.get("time").is_some_and(Value::is_string) {
            ctx.clock.set(time(op, "time", index)?);
        }
        let expected = op.get("expect").and_then(Value::as_str).unwrap_or("ok");
        // 결과(오류 종류)를 기록하고 기대와 맞는지 확인한다.
        let finish = |result: Result<(), StoreError>| -> Res<()> {
            let got = result.as_ref().err().map_or("ok", kind);
            println!("{index} {name} {got}");
            if got != expected {
                return Err(format!("{index}번 {name}: 결과 {got}, 기대 {expected}").into());
            }
            Ok(())
        };
        match name {
            "createLocked" => {
                ctx.ids.push(id("id")?);
                let source = op.get("source").and_then(Value::as_str).map(MemoID::new);
                let password = text(op, "password", index)?.as_bytes();
                let result = ctx.store.create_locked_memo(password, source.as_ref()).and_then(|created| {
                    if created == id("id").map_err(|e| StoreError::Other(e.to_string()))? {
                        Ok(())
                    } else {
                        Err(StoreError::Other("만들어진 ID가 다름".into()))
                    }
                });
                finish(result)?;
            }
            "unlock" => finish(ctx.store.unlock(&id("id")?, text(op, "password", index)?.as_bytes()))?,
            "relock" => {
                ctx.store.relock(&id("id")?);
                println!("{index} relock ok");
            }
            "changePassword" => finish(ctx.store.change_password(&id("id")?, text(op, "password", index)?.as_bytes()))?,
            "moveToPlain" => {
                ctx.ids.push(id("newId")?);
                let created = ctx.store.move_to_plain_memo(&id("id")?);
                finish(created.map(|_| ()))?;
            }
            "destroy" => finish(ctx.store.destroy_memo(&id("id")?))?,
            "saveLockedBody" => {
                let saved = ctx.store.save_body(&id("id")?, text(op, "body", index)?);
                let got = if saved { "ok" } else { "refused" };
                println!("{index} saveLockedBody {got}");
                if got != expected {
                    return Err(format!("{index}번 saveLockedBody: 결과 {got}, 기대 {expected}").into());
                }
            }
            "loadTrash" => {
                ctx.store.reload_trash();
                println!("{index} loadTrash ok");
            }
            "setFailures" => {
                let target = id("id")?;
                if let Some(value) = op.get("keychain").and_then(Value::as_i64) {
                    keys.write_failures(&target.raw_value, value)?;
                }
                if let Some(raw) = op.get("rawKeychain").and_then(Value::as_str) {
                    keys.write_raw_failures(&target.raw_value, raw)?;
                }
                if let Some(value) = op.get("header").and_then(Value::as_i64) {
                    let mut document = ctx.store.repository().load(&target)?;
                    document.meta.lock_failures = Some(value);
                    ctx.store.repository().save(&document)?;
                }
                println!("{index} setFailures ok");
            }
            "corruptBody" => {
                let mut document = ctx.store.repository().load(&id("id")?)?;
                let mut cipher = b64::decode(&document.body).filter(|c| c.len() > 14).ok_or("손상시킬 암호문이 없음")?;
                cipher[14] ^= 1;
                document.body = b64::encode(&cipher);
                ctx.store.repository().save(&document)?;
                println!("{index} corruptBody ok");
            }
            "flipByte" => {
                let path = ctx.data_dir.join(text(op, "path", index)?);
                let mut data = fs::read(&path)?;
                let offset = op.get("offset").and_then(Value::as_i64).unwrap_or(0);
                let at = if offset >= 0 { offset as usize } else { data.len() - (-offset) as usize };
                data[at] ^= 1;
                fs::write(&path, data)?;
                println!("{index} flipByte ok");
            }
            "writeFile" => {
                fs::write(ctx.data_dir.join(text(op, "path", index)?), text(op, "text", index)?)?;
                println!("{index} writeFile ok");
            }
            "assertBody" => {
                let want = text(op, "body", index)?;
                let result = ctx.store.decrypted_document(&id("id")?).and_then(|document| {
                    if document.body_str() == want {
                        Ok(())
                    } else {
                        Err(StoreError::Other("본문이 다름".into()))
                    }
                });
                finish(result)?;
            }
            "assertAttachment" => {
                let target = id("id")?;
                let attachment = text(op, "name", index)?;
                let want = b64::decode(text(op, "bytes", index)?).ok_or("base64 오류")?;
                let result = (|| -> Result<(), StoreError> {
                    let session = ctx.store.lock_session(&target).ok_or(StoreError::Locked)?;
                    let file = ctx.store.repository().attachments_directory(&target).join(format!("{attachment}.enc"));
                    let plain = session.open(&fs::read(file)?, Some(attachment))?;
                    if plain.as_slice() == want.as_slice() {
                        Ok(())
                    } else {
                        Err(StoreError::Other("첨부가 다름".into()))
                    }
                })();
                finish(result)?;
            }
            "assertFailures" => {
                let target = id("id")?;
                let in_keychain = keys.read_failures(&target.raw_value)?;
                let in_header = ctx.store.repository().load(&target)?.meta.lock_failures;
                let header_text = in_header.map_or("nil".to_string(), |v| v.to_string());
                println!("{index} assertFailures keychain={in_keychain} header={header_text}");
                if let Some(want) = op.get("keychain").and_then(Value::as_i64) {
                    if want != in_keychain {
                        return Err(format!("{index}번: 키체인 횟수 {in_keychain}, 기대 {want}").into());
                    }
                }
                if let Some(want) = op.get("header").and_then(Value::as_i64) {
                    if Some(want) != in_header {
                        return Err(format!("{index}번: 앞머리 횟수 {header_text}, 기대 {want}").into());
                    }
                }
            }
            "assertExists" => {
                let path = text(op, "path", index)?;
                let exists = ctx.data_dir.join(path).exists();
                println!("{index} assertExists {exists}");
                if exists != op.get("exists").and_then(Value::as_bool).unwrap_or(true) {
                    return Err(format!("{index}번: {path} 존재 {exists}").into());
                }
            }
            _ => {
                if !ctx.apply(op, index)? {
                    return Err(format!("알 수 없는 연산: {name}").into());
                }
                println!("{index} {name} ok");
            }
        }
    }
    Ok(())
}
