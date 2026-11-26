//! 상태 쌍의 날짜는 오차 허용 없이 비교한다. 날짜는 2001년 기준 Double이다.
use mdemo_core::{json, meta::MemoDate, store::atomic_write};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};
#[derive(Default, Clone, Debug)]
pub struct SyncState {
    pub dates: BTreeMap<String, MemoDate>,
    pub hashes: BTreeMap<String, Vec<String>>,
}
#[derive(Serialize, Deserialize)]
struct HashRecord {
    date: MemoDate,
    hashes: Vec<String>,
}
pub fn hashes_path(path: &Path) -> PathBuf {
    path.with_extension("hashes.json")
}
impl SyncState {
    pub fn load(path: &Path) -> Self {
        let mut state = Self::default();
        state.dates = fs::read(path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        if let Some(records) = fs::read(hashes_path(path))
            .ok()
            .and_then(|b| serde_json::from_slice::<BTreeMap<String, HashRecord>>(&b).ok())
        {
            for (key, record) in records {
                if state.dates.get(&key) == Some(&record.date) {
                    state.hashes.insert(key, record.hashes);
                }
            }
        }
        state
    }
    pub fn save(&self, path: &Path) {
        // Swift처럼 저장 실패를 호출자에게 전파하지 않는다.
        let _ = self.try_save(path);
    }
    pub fn try_save(&self, path: &Path) -> crate::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        atomic_write(path, &json::encode(&self.dates, false, true)?)?;
        let records: BTreeMap<_, _> = self
            .hashes
            .iter()
            .filter_map(|(key, hashes)| {
                self.dates.get(key).map(|date| {
                    (
                        key,
                        HashRecord {
                            date: *date,
                            hashes: hashes.clone(),
                        },
                    )
                })
            })
            .collect();
        atomic_write(&hashes_path(path), &json::encode(&records, false, true)?)?;
        Ok(())
    }
    pub fn record(&mut self, key: &str, date: MemoDate, hashes: Vec<String>) {
        self.dates.insert(key.into(), date);
        let mut unique = Vec::new();
        for hash in hashes {
            if !unique.contains(&hash) {
                unique.push(hash);
            }
        }
        self.hashes.insert(key.into(), unique);
    }
    pub fn forget(&mut self, key: &str) {
        self.dates.remove(key);
        self.hashes.remove(key);
    }
}
