//! 메모리 가짜 드라이브. 네트워크와 실제 사용자 설정에는 닿지 않는다.
use crate::drive::*;
use mdemo_core::meta::MemoDate;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
#[derive(Default, Serialize, Deserialize)]
pub struct FakeDrive {
    pub counter: u64,
    pub files: BTreeMap<String, DriveFile>,
    pub contents: BTreeMap<String, Vec<u8>>,
    pub calls: Vec<String>,
    pub uploaded_paths: Vec<String>,
    pub deleted_paths: Vec<String>,
    pub failures: BTreeSet<String>,
}
impl FakeDrive {
    fn check(&mut self, op: &str) -> std::result::Result<(), DriveError> {
        self.calls.push(op.into());
        let ordinal = self
            .calls
            .iter()
            .rev()
            .take_while(|s| s.as_str() != "list")
            .filter(|s| s.as_str() == op)
            .count();
        if self.failures.contains(op) || self.failures.contains(&format!("{op}:{ordinal}")) {
            Err(DriveError::Http(500, "실패 주입".into()))
        } else {
            Ok(())
        }
    }
    fn store(&mut self, mut f: DriveFile, data: Option<&[u8]>) -> DriveFile {
        if let Some(data) = data {
            f.md5 = Some(md5_bytes(data));
            self.contents.insert(f.id.clone(), data.to_vec());
        }
        f.modified_time = Some(MemoDate(123.));
        self.files.insert(f.id.clone(), f.clone());
        f
    }
    fn new_file(&mut self, name: &str, parent: Option<&str>, folder: bool) -> DriveFile {
        self.counter += 1;
        DriveFile {
            id: format!("id{}", self.counter),
            name: name.into(),
            mime_type: if folder {
                FOLDER_MIME
            } else {
                "application/octet-stream"
            }
            .into(),
            md5: None,
            parents: parent.map(|p| vec![p.into()]).unwrap_or_default(),
            modified_time: None,
        }
    }
    pub fn path(&self, f: &DriveFile) -> String {
        let mut parts = vec![f.name.clone()];
        let mut current = f;
        let mut seen = BTreeSet::new();
        while let Some(parent) = current.parents.first().and_then(|id| self.files.get(id)) {
            if !seen.insert(parent.id.clone()) {
                break;
            }
            if parent.parents.is_empty() && parent.name == "MDemo" {
                break;
            }
            parts.insert(0, parent.name.clone());
            current = parent;
        }
        parts.join("/")
    }
    pub fn paths(&self) -> BTreeMap<String, Vec<u8>> {
        self.files
            .values()
            .filter(|f| !f.is_folder())
            .map(|f| {
                (
                    self.path(f),
                    self.contents.get(&f.id).cloned().unwrap_or_default(),
                )
            })
            .collect()
    }
    pub fn put(&mut self, path: &str, data: &[u8]) -> std::result::Result<(), DriveError> {
        let root = self
            .files
            .values()
            .find(|f| f.is_folder() && f.name == "MDemo" && f.parents.is_empty())
            .map(|f| f.id.clone());
        let mut parent = match root {
            Some(id) => id,
            None => self.create_folder("MDemo", None)?.id,
        };
        let parts: Vec<_> = path.split('/').collect();
        for name in &parts[..parts.len() - 1] {
            let found = self
                .files
                .values()
                .find(|f| f.is_folder() && f.name == *name && f.parents == [parent.clone()])
                .map(|f| f.id.clone());
            parent = match found {
                Some(id) => id,
                None => self.create_folder(name, Some(&parent))?.id,
            };
        }
        let name = parts.last().ok_or(DriveError::InvalidResponse)?;
        let found = self
            .files
            .values()
            .find(|f| !f.is_folder() && f.name == *name && f.parents == [parent.clone()])
            .map(|f| f.id.clone());
        match found {
            Some(id) => {
                self.update(&id, data)?;
            }
            None => {
                self.upload(name, Some(&parent), data)?;
            }
        }
        Ok(())
    }
    pub fn remove_remotely(&mut self, path: &str) {
        if let Some(id) = self
            .files
            .values()
            .find(|f| self.path(f) == path)
            .map(|f| f.id.clone())
        {
            self.files.remove(&id);
            self.contents.remove(&id);
        }
    }
}
impl DriveApi for FakeDrive {
    fn list(&mut self) -> std::result::Result<Vec<DriveFile>, DriveError> {
        self.check("list")?;
        Ok(self.files.values().cloned().collect())
    }
    fn download(&mut self, id: &str) -> std::result::Result<Vec<u8>, DriveError> {
        self.check("download")?;
        self.contents.get(id).cloned().ok_or(DriveError::NotFound)
    }
    fn upload(
        &mut self,
        name: &str,
        parent: Option<&str>,
        data: &[u8],
    ) -> std::result::Result<DriveFile, DriveError> {
        self.check("upload")?;
        let f = self.new_file(name, parent, false);
        let f = self.store(f, Some(data));
        self.uploaded_paths.push(self.path(&f));
        Ok(f)
    }
    fn update(&mut self, id: &str, data: &[u8]) -> std::result::Result<DriveFile, DriveError> {
        self.check("update")?;
        let f = self.files.get(id).cloned().ok_or(DriveError::NotFound)?;
        let f = self.store(f, Some(data));
        self.uploaded_paths.push(self.path(&f));
        Ok(f)
    }
    fn create_folder(
        &mut self,
        name: &str,
        parent: Option<&str>,
    ) -> std::result::Result<DriveFile, DriveError> {
        self.check("createFolder")?;
        let f = self.new_file(name, parent, true);
        Ok(self.store(f, None))
    }
    fn delete(&mut self, id: &str) -> std::result::Result<(), DriveError> {
        self.check("delete")?;
        let f = self.files.remove(id).ok_or(DriveError::NotFound)?;
        self.deleted_paths.push(self.path(&f));
        self.contents.remove(id);
        let children: Vec<_> = self
            .files
            .values()
            .filter(|f| f.parents.iter().any(|p| p == id))
            .map(|f| f.id.clone())
            .collect();
        for child in children {
            self.files.remove(&child);
            self.contents.remove(&child);
        }
        Ok(())
    }
}
