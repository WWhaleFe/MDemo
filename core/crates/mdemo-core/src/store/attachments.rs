//! 첨부 파일 저장 · 목록 · 삭제 (Swift `AttachmentImages`의 파일 부분).
//!
//! 이미지 디코딩과 재인코딩, 무작위 파일 이름 만들기는 플랫폼에 남긴다.
//! 여기서는 정해진 이름과 바이트를 첨부 폴더에 두고 지우고 정리하기만 한다.

use super::{
    atomic_write, modified_time, repository::FileMemoRepository, visible_entries, StoreError,
    StoreResult,
};
use crate::{id::MemoID, meta::MemoDate};
use std::{fs, path::Path};

pub const FOLDER_NAME: &str = "attachments";

/// 첨부 폴더 밖으로 나가는 이름을 막는다.
fn check_name(name: &str) -> StoreResult<()> {
    if name.is_empty() || name.starts_with('.') || name.contains(['/', '\\', '\0']) {
        return Err(StoreError::BadName(name.into()));
    }
    Ok(())
}

impl FileMemoRepository {
    /// 첨부 파일을 저장한다. 폴더는 처음 쓸 때 만든다.
    pub fn save_attachment(&self, id: &MemoID, name: &str, bytes: &[u8]) -> StoreResult<()> {
        check_name(name)?;
        let directory = self.attachments_directory(id);
        fs::create_dir_all(&directory)?;
        Ok(atomic_write(&directory.join(name), bytes)?)
    }

    /// 첨부 파일 이름 목록(이름순). 폴더가 없으면 비어 있다.
    pub fn list_attachments(&self, id: &MemoID) -> Vec<String> {
        visible_entries(&self.attachments_directory(id))
            .unwrap_or_default()
            .into_iter()
            .filter(|(_, path)| path.is_file())
            .map(|(name, _)| name)
            .collect()
    }

    /// 첨부 파일을 지운다. 있었으면 true.
    pub fn remove_attachment(&self, id: &MemoID, name: &str) -> StoreResult<bool> {
        check_name(name)?;
        match fs::remove_file(self.attachments_directory(id).join(name)) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.into()),
        }
    }

    /// 모든 메모의 첨부 폴더를 훑어 본문에서 쓰지 않는 오래된 파일을 지운다 (IMG-07).
    /// 첨부 폴더가 없거나 잠긴 메모, 본문을 읽지 못하는 메모는 건드리지 않는다.
    pub fn prune_unused_attachments(&self, modified_before: MemoDate) -> usize {
        let Ok(destroyed) = self.destroyed() else { return 0 };
        let entries = visible_entries(&self.root().join("memos")).unwrap_or_default();
        let mut removed = 0;
        for (name, _) in entries {
            let id = MemoID::new(name);
            if !id.is_valid() || destroyed.contains(&id.raw_value) {
                continue;
            }
            let attachments = self.attachments_directory(&id);
            if !attachments.exists() {
                continue;
            }
            let Ok(document) = self.load(&id) else { continue };
            if document.meta.is_locked {
                continue;
            }
            removed += prune_unused(&attachments, &document.body, modified_before);
        }
        removed
    }
}

/// 본문 어디에서도 쓰지 않는 첨부 가운데 `date`보다 오래된 일반 파일을 지운다 (Swift `pruneUnused`).
/// 수정 시각을 읽지 못하면 남긴다.
pub fn prune_unused(directory: &Path, body: &str, older_than: MemoDate) -> usize {
    let Ok(entries) = visible_entries(directory) else { return 0 };
    let mut removed = 0;
    for (name, path) in entries {
        if !path.is_file() {
            continue;
        }
        let Ok(modified) = modified_time(&path) else { continue };
        if !(modified < older_than) || body.contains(&name) {
            continue;
        }
        if fs::remove_file(&path).is_ok() {
            removed += 1;
        }
    }
    removed
}
