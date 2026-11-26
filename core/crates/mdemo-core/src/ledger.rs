use crate::id::MemoID;
use std::{collections::BTreeSet, fs, path::Path};
pub fn decode(bytes: &[u8]) -> Result<BTreeSet<String>, serde_json::Error> {
    Ok(serde_json::from_slice::<Vec<String>>(bytes)?
        .into_iter()
        .filter(|id| MemoID::new(id).is_valid())
        .collect())
}
pub fn read(path: &Path) -> Result<BTreeSet<String>, Box<dyn std::error::Error>> {
    if !path.exists() {
        return Ok(BTreeSet::new());
    }
    Ok(decode(&fs::read(path)?)?)
}
/// 기존 장부와 합친 뒤 임시 파일을 동기화하고 교체한다.
static MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());
pub fn write(path: &Path, ids: &BTreeSet<String>) -> Result<(), Box<dyn std::error::Error>> {
    let _guard = MUTEX.lock().map_err(|_| "장부 잠금 오류")?;
    let mut merged = read(path)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    merged.extend(ids.iter().cloned());
    let bytes = crate::json::encode(&merged, false, true)?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, bytes)?;
    fs::OpenOptions::new().write(true).open(&tmp)?.sync_all()?;
    fs::rename(tmp, path)?;
    Ok(())
}
#[cfg(test)]
mod tests {
    #[test]
    fn filters_and_deduplicates() {
        assert_eq!(
            super::decode(br#"["bad","01ARZ3NDEKTSV4RRFFQ69G5F00","01ARZ3NDEKTSV4RRFFQ69G5F00"]"#)
                .unwrap()
                .len(),
            1
        );
        assert!(super::decode(b"{}").is_err());
    }
}
#[cfg(test)]
mod persistence_tests {
    #[test]
    fn concurrent_writes_only_grow_both_ledgers() {
        use super::*;
        let root = std::env::temp_dir().join(format!(
            "mdemo-ledger-{}",
            crate::id::MemoID::generate().unwrap()
        ));
        for name in ["destroyed.json", "local-only.json"] {
            let path = root.join(name);
            std::thread::scope(|scope| {
                for suffix in ["00", "01"] {
                    let path = path.clone();
                    scope.spawn(move || {
                        write(
                            &path,
                            &BTreeSet::from([format!("01ARZ3NDEKTSV4RRFFQ69G5F{suffix}")]),
                        )
                        .unwrap();
                    });
                }
            });
            write(&path, &BTreeSet::new()).unwrap();
            assert_eq!(read(&path).unwrap().len(), 2);
        }
        fs::remove_dir_all(root).unwrap();
    }
}
