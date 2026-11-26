//! ZIP 바이트 대신 풀었을 때 트리와 내용, Swift ditto와의 상호 가져오기를 계약으로 삼는다.
use crate::{files, Result};
use mdemo_core::{
    frontmatter,
    id::MemoID,
    ledger,
    store::{secure_delete, Clock, FileMemoRepository, SystemClock},
};
use mdemo_crypto::{KeyStore, MemoryKeyStore};
use std::{
    collections::BTreeSet,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::Arc,
};
pub struct BackupService {
    pub data_root: PathBuf,
    pub keys: Arc<dyn KeyStore>,
    pub clock: Arc<dyn Clock>,
}
struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Result<Self> {
        let p = std::env::temp_dir().join(format!(
            "mdemo-backup-{}",
            MemoID::generate().map_err(|e| e.to_string())?
        ));
        fs::create_dir_all(&p)?;
        Ok(Self(p))
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
impl BackupService {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            data_root: root.into(),
            keys: Arc::new(MemoryKeyStore::default()),
            clock: Arc::new(SystemClock),
        }
    }
    pub fn export_backup(&self, destination: &Path) -> Result<usize> {
        let scratch = Scratch::new()?;
        let name = self.data_root.file_name().ok_or("데이터 폴더 이름 없음")?;
        let filtered = scratch.0.join(name);
        fs::create_dir_all(&filtered)?;
        let mut private = ledger::read(&self.data_root.join("destroyed.json"))?;
        private.extend(ledger::read(&self.data_root.join("local-only.json"))?);
        let mut excluded = 0;
        for folder in ["memos", "trash"] {
            fs::create_dir_all(filtered.join(folder))?;
            for e in fs::read_dir(self.data_root.join(folder))
                .into_iter()
                .flatten()
            {
                let e = e?;
                let p = e.path();
                let id = e.file_name().to_string_lossy().into_owned();
                let doc = fs::read_to_string(p.join("memo.md"))
                    .ok()
                    .and_then(|s| frontmatter::decode(&s).ok());
                if private.contains(&id) || doc.is_none_or(|d| d.meta.is_locked) {
                    excluded += 1;
                    continue;
                }
                files::copy_tree(&p, &filtered.join(folder).join(id))?;
            }
        }
        for name in [
            "groups.json",
            "board.json",
            "destroyed.json",
            "local-only.json",
        ] {
            let source = self.data_root.join(name);
            if source.exists() {
                files::copy_tree(&source, &filtered.join(name))?;
            }
        }
        let mut zip = zip::ZipWriter::new(fs::File::create(destination)?);
        fn add(zip: &mut zip::ZipWriter<fs::File>, base: &Path, path: &Path) -> Result<()> {
            let relative = path
                .strip_prefix(base)?
                .components()
                .map(|c| c.as_os_str().to_string_lossy())
                .collect::<Vec<_>>()
                .join("/");
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            if path.is_dir() {
                zip.add_directory(format!("{relative}/"), options)?;
                let mut entries: Vec<_> = fs::read_dir(path)?.collect::<std::io::Result<_>>()?;
                entries.sort_by_key(|e| e.file_name());
                for e in entries {
                    add(zip, base, &e.path())?;
                }
            } else {
                zip.start_file(relative, options)?;
                zip.write_all(&fs::read(path)?)?;
            }
            Ok(())
        }
        add(&mut zip, &scratch.0, &filtered)?;
        zip.finish()?;
        Ok(excluded)
    }
    pub fn import_backup(&self, archive: &Path, replace: bool) -> Result<usize> {
        let scratch = Scratch::new()?;
        let unpack = scratch.0.join("unpacked");
        fs::create_dir_all(&unpack)?;
        let mut zip = zip::ZipArchive::new(fs::File::open(archive)?)?;
        for index in 0..zip.len() {
            let mut entry = zip.by_index(index)?;
            // Windows의 구분자와 드라이브 접두사도 거부해 플랫폼마다 같은 경계를 지킨다.
            if entry.name().contains('\\') || entry.name().contains(':') {
                return Err("ZIP 경로가 데이터 폴더 밖을 가리킵니다".into());
            }
            // ditto는 UTF-8 이름에도 언어 비트를 생략한다. 원시 이름이 UTF-8이면 그대로 읽는다.
            let name = std::str::from_utf8(entry.name_raw())
                .unwrap_or(entry.name())
                .to_owned();
            if name.starts_with('/')
                || name.contains('\\')
                || name.contains(':')
                || name.contains('\0')
                || name.split('/').any(|p| p == "..")
            {
                return Err("안전하지 않은 ZIP 경로".into());
            }
            let relative = PathBuf::from(name);
            if relative.components().any(|c| c.as_os_str() == "__MACOSX") {
                continue;
            }
            if entry.unix_mode().is_some_and(|m| m & 0o170000 == 0o120000) {
                return Err("ZIP 심볼릭 링크는 가져오지 않습니다".into());
            }
            let target = unpack.join(relative);
            if entry.is_dir() {
                fs::create_dir_all(target)?;
            } else {
                fs::create_dir_all(target.parent().ok_or("부모 없음")?)?;
                let mut bytes = Vec::new();
                entry.read_to_end(&mut bytes)?;
                fs::write(target, bytes)?;
            }
        }
        let source = if unpack.join("memos").exists() {
            unpack.clone()
        } else {
            files::entries(&unpack)
                .into_iter()
                .map(|(_, p)| p)
                .find(|p| p.join("memos").exists())
                .ok_or("메모 폴더가 없는 백업")?
        };
        let mut destroyed = ledger::read(&self.data_root.join("destroyed.json"))?;
        destroyed.extend(ledger::read(&source.join("destroyed.json"))?);
        ledger::write(&self.data_root.join("destroyed.json"), &destroyed)?;
        let mut skipped = BTreeSet::new();
        for id in &destroyed {
            self.keys.delete(id)?;
            secure_delete::remove_copies(&MemoID::new(id), &self.data_root)?;
            for folder in ["memos", "trash"] {
                let p = source.join(folder).join(id);
                if p.exists() {
                    secure_delete::remove(&p, None)?;
                    skipped.insert(id.clone());
                }
            }
        }
        ledger::write(&source.join("destroyed.json"), &destroyed)?;
        if replace {
            let repo = FileMemoRepository::with_keys(
                &self.data_root,
                self.clock.clone(),
                self.keys.clone(),
            )?;
            for (folder, list) in [
                ("memos", repo.load_summaries()?),
                ("trash", repo.load_trash_summaries()?),
            ] {
                for memo in list.into_iter().filter(|m| m.meta.is_locked) {
                    let target = source.join(folder).join(&memo.meta.id.raw_value);
                    files::remove(&target)?;
                    files::copy_tree(
                        &self.data_root.join(folder).join(&memo.meta.id.raw_value),
                        &target,
                    )?;
                    mdemo_core::store::repository::exclude_from_backup(&target)?;
                }
            }
            files::replace_tree(&source, &self.data_root)?;
        } else {
            for folder in ["memos", "trash"] {
                let dest = self.data_root.join(folder);
                fs::create_dir_all(&dest)?;
                for (name, p) in files::entries(&source.join(folder)) {
                    let target = dest.join(name);
                    if !target.exists() {
                        files::copy_tree(&p, &target)?;
                    }
                }
            }
            ledger::write(&self.data_root.join("destroyed.json"), &destroyed)?;
        }
        Ok(skipped.len())
    }
}
