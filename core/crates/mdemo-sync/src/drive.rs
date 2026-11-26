//! 통신 구현은 플랫폼이 제공한다. 이 모듈은 파일 비교와 요청 순서만 정한다.
use crate::{files, md5, Result, SyncMode, SyncReport, SyncService};
use mdemo_core::{json, ledger, meta::MemoDate, store::atomic_write};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    fs,
    path::PathBuf,
};
pub const FOLDER_MIME: &str = "application/vnd.google-apps.folder";
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DriveFile {
    pub id: String,
    pub name: String,
    pub mime_type: String,
    pub md5: Option<String>,
    pub parents: Vec<String>,
    pub modified_time: Option<MemoDate>,
}
impl DriveFile {
    pub fn is_folder(&self) -> bool {
        self.mime_type == FOLDER_MIME
    }
    pub fn change_token(&self) -> String {
        self.md5
            .clone()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| {
                let t = self.modified_time.map_or(0., |d| d.0 + 978_307_200.);
                let mut s = json::double(t);
                if !s.contains('.') && !s.contains('e') {
                    s.push_str(".0");
                }
                format!("t:{s}")
            })
    }
}
#[derive(Debug)]
pub enum DriveError {
    NotFound,
    Http(i32, String),
    InvalidResponse,
    Incomplete(usize),
}
impl std::fmt::Display for DriveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "드라이브 오류: {self:?}")
    }
}
impl std::error::Error for DriveError {}
/// Swift DriveAPI와 같은 여섯 연산. 플랫폼은 비동기 HTTP를 이 경계에서 연결한다.
pub trait DriveApi {
    fn list(&mut self) -> std::result::Result<Vec<DriveFile>, DriveError>;
    fn download(&mut self, id: &str) -> std::result::Result<Vec<u8>, DriveError>;
    fn upload(
        &mut self,
        name: &str,
        parent_id: Option<&str>,
        data: &[u8],
    ) -> std::result::Result<DriveFile, DriveError>;
    fn update(&mut self, id: &str, data: &[u8]) -> std::result::Result<DriveFile, DriveError>;
    fn create_folder(
        &mut self,
        name: &str,
        parent_id: Option<&str>,
    ) -> std::result::Result<DriveFile, DriveError>;
    fn delete(&mut self, id: &str) -> std::result::Result<(), DriveError>;
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileRecord {
    #[serde(rename = "fileID")]
    pub file_id: String,
    #[serde(rename = "remoteMD5")]
    pub remote_md5: String,
    #[serde(rename = "syncedMD5")]
    pub synced_md5: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub purge: Option<bool>,
}
#[derive(Default, Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DriveState {
    #[serde(rename = "rootID", skip_serializing_if = "Option::is_none")]
    pub root_id: Option<String>,
    pub files: BTreeMap<String, FileRecord>,
    pub folders: BTreeMap<String, String>,
    pub completed_once: bool,
}
impl DriveState {
    pub fn load(path: &std::path::Path) -> Self {
        fs::read(path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }
    pub fn save(&self, path: &std::path::Path) {
        let _ = (|| -> Result<()> {
            if let Some(p) = path.parent() {
                fs::create_dir_all(p)?;
            }
            atomic_write(path, &json::encode(self, false, true)?)?;
            Ok(())
        })();
    }
}
#[derive(Default)]
struct Tree {
    root: Option<String>,
    files: BTreeMap<String, DriveFile>,
    folders: BTreeMap<String, String>,
}
/// 내려받은 파일을 거울 밖에 준비하고 실패한 회차의 임시 파일을 정리한다.
struct DownloadStaging(PathBuf);
impl Drop for DownloadStaging {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
pub fn md5_bytes(data: &[u8]) -> String {
    md5::digest(data)
}
fn file_md5(path: &std::path::Path) -> Option<String> {
    fs::read(path).ok().map(|b| md5::digest(&b))
}
fn ignored(name: &str) -> bool {
    name.is_empty()
        || name.starts_with('.')
        || name.ends_with(".tmp")
        || name.contains('/')
        || name.contains('\\')
        || name.contains(':')
}
pub fn blocked(path: &str, ids: &BTreeSet<String>) -> bool {
    let parts: Vec<_> = path.split('/').collect();
    parts.len() >= 2 && ["memos", "trash"].contains(&parts[0]) && ids.contains(parts[1])
}
pub struct DriveMirrorSync {
    pub service: SyncService,
    pub state_url: PathBuf,
}
impl DriveMirrorSync {
    pub fn sync(&self, api: &mut dyn DriveApi, mode: SyncMode) -> Result<SyncReport> {
        let mut state = DriveState::load(&self.state_url);
        if mode != SyncMode::Push {
            self.download(api, &mut state)?;
        }
        let report = self.service.sync(mode)?;
        if mode != SyncMode::Pull {
            self.upload(api, &mut state)?;
        }
        Ok(report)
    }
    pub fn enforce_privacy(&self, api: &mut dyn DriveApi) -> Result<SyncReport> {
        let report = self.service.enforce_privacy()?;
        let mut state = DriveState::load(&self.state_url);
        if state.completed_once || !state.files.is_empty() {
            let _ = self.upload(api, &mut state);
        }
        Ok(report)
    }
    fn blocked_ids(&self) -> BTreeSet<String> {
        let mut ids = BTreeSet::new();
        for root in [&self.service.local_root, &self.service.remote_root] {
            for name in ["destroyed.json", "local-only.json"] {
                ids.extend(ledger::read(&root.join(name)).unwrap_or_default());
            }
        }
        ids
    }
    fn fetch(&self, api: &mut dyn DriveApi, state: &DriveState) -> Result<Tree> {
        let all = api.list()?;
        let folder_ids: BTreeSet<_> = all
            .iter()
            .filter(|f| f.is_folder())
            .map(|f| f.id.clone())
            .collect();
        let root = state
            .root_id
            .clone()
            .filter(|id| folder_ids.contains(id))
            .or_else(|| {
                all.iter()
                    .filter(|f| {
                        f.is_folder()
                            && f.name == "MDemo"
                            && !f.parents.iter().any(|p| folder_ids.contains(p))
                    })
                    .max_by(|a, b| {
                        a.modified_time
                            .partial_cmp(&b.modified_time)
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .map(|f| f.id.clone())
            });
        let mut tree = Tree {
            root: root.clone(),
            ..Tree::default()
        };
        let Some(root) = root else {
            return Ok(tree);
        };
        let mut queue = VecDeque::from([(root, String::new())]);
        let mut visited = BTreeSet::new();
        while let Some((parent, prefix)) = queue.pop_front() {
            if !visited.insert(parent.clone()) {
                continue;
            }
            let mut names: BTreeMap<String, &DriveFile> = BTreeMap::new();
            for f in all
                .iter()
                .filter(|f| f.parents.contains(&parent) && !ignored(&f.name))
            {
                if names
                    .get(&f.name)
                    .is_none_or(|old| f.modified_time > old.modified_time)
                {
                    names.insert(f.name.clone(), f);
                }
            }
            for (name, f) in names {
                let path = if prefix.is_empty() {
                    name
                } else {
                    format!("{prefix}/{name}")
                };
                if f.is_folder() {
                    tree.folders.insert(path.clone(), f.id.clone());
                    queue.push_back((f.id.clone(), path));
                } else {
                    tree.files.insert(path, f.clone());
                }
            }
        }
        Ok(tree)
    }
    fn download(&self, api: &mut dyn DriveApi, state: &mut DriveState) -> Result<()> {
        let tree = self.fetch(api, state)?;
        let ids = self.blocked_ids();
        let mut updated = state.clone();
        let mut staged = Vec::new();
        let staging = DownloadStaging(
            self.service
                .remote_root
                .parent()
                .ok_or("거울 부모 없음")?
                .join(format!(
                    ".staging-{}",
                    mdemo_core::id::MemoID::generate().map_err(|e| e.to_string())?
                )),
        );
        // 전체 내려받기가 성공하기 전에는 거울과 상태에 쓰지 않는다.
        for (path, file) in &tree.files {
            let target = self.service.remote_root.join(path);
            if blocked(path, &ids) {
                if updated
                    .files
                    .get(path)
                    .is_none_or(|r| r.purge != Some(true))
                {
                    updated.files.insert(
                        path.clone(),
                        FileRecord {
                            file_id: file.id.clone(),
                            remote_md5: file.change_token(),
                            synced_md5: String::new(),
                            purge: Some(true),
                        },
                    );
                }
                continue;
            }
            if let Some(record) = updated.files.get_mut(path) {
                if record.remote_md5 == file.change_token() {
                    record.file_id = file.id.clone();
                    continue;
                }
            } else if let Some(local) = file_md5(&target) {
                if Some(&local) == file.md5.as_ref() {
                    updated.files.insert(
                        path.clone(),
                        FileRecord {
                            file_id: file.id.clone(),
                            remote_md5: file.change_token(),
                            synced_md5: local,
                            purge: None,
                        },
                    );
                    continue;
                }
            }
            fs::create_dir_all(&staging.0)?;
            let downloaded = api.download(&file.id)?;
            let temporary = staging.0.join(staged.len().to_string());
            fs::write(&temporary, &downloaded)?;
            staged.push((path.clone(), file.clone(), temporary));
        }
        fs::create_dir_all(&self.service.remote_root)?;
        for (path, file, temporary) in staged {
            let data = fs::read(temporary)?;
            let target = self.service.remote_root.join(&path);
            fs::create_dir_all(target.parent().ok_or("부모 없음")?)?;
            atomic_write(&target, &data)?;
            updated.files.insert(
                path,
                FileRecord {
                    file_id: file.id.clone(),
                    remote_md5: file.change_token(),
                    synced_md5: md5::digest(&data),
                    purge: None,
                },
            );
        }
        let removed: Vec<_> = updated
            .files
            .iter()
            .filter(|(p, r)| {
                !tree.files.contains_key(*p) && (r.purge == Some(true) || updated.completed_once)
            })
            .map(|(p, r)| (p.clone(), r.purge))
            .collect();
        for (path, purge) in removed {
            if purge != Some(true) {
                let target = self.service.remote_root.join(&path);
                let _ = files::remove(&target);
                let mut parent = target.parent();
                while let Some(p) = parent {
                    if p == self.service.remote_root {
                        break;
                    }
                    if fs::remove_dir(p).is_err() {
                        break;
                    }
                    parent = p.parent();
                }
            }
            updated.files.remove(&path);
        }
        updated.root_id = tree.root.or(updated.root_id);
        updated.folders = tree.folders;
        *state = updated;
        state.save(&self.state_url);
        Ok(())
    }
    fn walk(&self) -> BTreeMap<String, String> {
        fn visit(
            base: &std::path::Path,
            path: &std::path::Path,
            out: &mut BTreeMap<String, String>,
        ) {
            for (name, p) in files::entries(path) {
                if name.ends_with(".tmp") {
                    continue;
                }
                let Ok(meta) = fs::symlink_metadata(&p) else {
                    continue;
                };
                if meta.file_type().is_symlink() {
                    continue;
                }
                if meta.is_dir() {
                    visit(base, &p, out);
                } else if meta.is_file() {
                    if let Some(hash) = file_md5(&p) {
                        if let Ok(rel) = p.strip_prefix(base) {
                            let name = rel
                                .components()
                                .map(|s| s.as_os_str().to_string_lossy())
                                .collect::<Vec<_>>()
                                .join("/");
                            #[cfg(target_os = "macos")]
                            let name = mdemo_core::nfd(&name);
                            out.insert(name, hash);
                        }
                    }
                }
            }
        }
        let mut out = BTreeMap::new();
        visit(
            &self.service.remote_root,
            &self.service.remote_root,
            &mut out,
        );
        out
    }
    fn folder(
        &self,
        api: &mut dyn DriveApi,
        path: &str,
        state: &mut DriveState,
    ) -> Result<Option<String>> {
        if state.root_id.is_none() {
            state.root_id = Some(api.create_folder("MDemo", None)?.id);
        }
        let mut current = state.root_id.clone();
        let mut prefix = String::new();
        for name in path.split('/').filter(|s| !s.is_empty()) {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(name);
            if let Some(id) = state.folders.get(&prefix) {
                current = Some(id.clone());
            } else {
                let id = api.create_folder(name, current.as_deref())?.id;
                state.folders.insert(prefix.clone(), id.clone());
                current = Some(id);
            }
        }
        Ok(current)
    }
    fn upload(&self, api: &mut dyn DriveApi, state: &mut DriveState) -> Result<()> {
        let ids = self.blocked_ids();
        let mirror: BTreeMap<_, _> = self
            .walk()
            .into_iter()
            .filter(|(p, _)| !blocked(p, &ids))
            .collect();
        let mut failed = 0;
        for (path, hash) in &mirror {
            if state.files.get(path).is_some_and(|r| r.synced_md5 == *hash) {
                continue;
            }
            let result = (|| -> Result<DriveFile> {
                let data = fs::read(self.service.remote_root.join(path))?;
                let (parent, name) = path.rsplit_once('/').unwrap_or(("", path));
                let folder = self.folder(api, parent, state)?;
                if let Some(record) = state.files.get(path).filter(|r| r.purge != Some(true)) {
                    match api.update(&record.file_id, &data) {
                        Ok(f) => return Ok(f),
                        Err(DriveError::NotFound) => (),
                        Err(e) => return Err(e.into()),
                    }
                }
                Ok(api.upload(name, folder.as_deref(), &data)?)
            })();
            match result {
                Ok(f) => {
                    state.files.insert(
                        path.clone(),
                        FileRecord {
                            file_id: f.id.clone(),
                            remote_md5: f.change_token(),
                            synced_md5: hash.clone(),
                            purge: None,
                        },
                    );
                }
                Err(_) => failed += 1,
            }
        }
        let removed: Vec<_> = state
            .files
            .iter()
            .filter(|(p, r)| {
                !mirror.contains_key(*p) && (state.completed_once || r.purge == Some(true))
            })
            .map(|(p, r)| (p.clone(), r.clone()))
            .collect();
        let mut purged = 0;
        for (path, r) in removed {
            match api.delete(&r.file_id) {
                Ok(()) | Err(DriveError::NotFound) => {
                    state.files.remove(&path);
                    if r.purge == Some(true) {
                        purged += 1;
                    }
                }
                Err(_) => failed += 1,
            }
        }
        if state.completed_once || purged > 0 {
            let mut folders: Vec<_> = state.folders.clone().into_iter().collect();
            folders.sort_by(|a, b| b.0.chars().count().cmp(&a.0.chars().count()));
            for (path, id) in folders {
                let prefix = format!("{path}/");
                if state.files.keys().any(|p| p.starts_with(&prefix))
                    || state.folders.keys().any(|p| p.starts_with(&prefix))
                {
                    continue;
                }
                match api.delete(&id) {
                    Ok(()) | Err(DriveError::NotFound) => {
                        state.folders.remove(&path);
                    }
                    Err(_) => (),
                }
            }
        }
        if failed == 0 {
            state.completed_once = true;
        }
        state.save(&self.state_url);
        if failed > 0 {
            return Err(DriveError::Incomplete(failed).into());
        }
        Ok(())
    }
}
