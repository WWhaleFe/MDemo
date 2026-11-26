//! 안전 삭제 (Swift `SecureMemoDeletion`). 같은 길이의 난수로 덮고 동기화한 뒤 지운다.
//!
//! APFS 스냅샷, SSD의 물리 블록, Windows의 NTFS 로그까지 지웠다고 보장하지는 않는다(Swift와 같다).
//! Swift는 `O_NOFOLLOW`로 열어 심볼릭 링크를 따라가지 않는다. 여기서는 열기 전에 `symlink_metadata`로
//! 종류를 확인한다. 확인과 열기 사이에 파일이 링크로 바뀌는 경쟁은 막지 못한다(외부 크레이트 없이
//! 플랫폼 플래그를 쓸 수 없어서). 알려진 차이로 `docs/hidden-behaviors.md`에 적었다.

use super::{StoreError, StoreResult};
use crate::id::MemoID;
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

/// 폴더 하나를 열어 동기화한다. Windows는 폴더를 일반 방식으로 열 수 없어 건너뛴다(P8에서 정한다).
#[cfg(not(windows))]
fn synchronize_directory(directory: &Path) -> StoreResult<()> {
    fs::File::open(directory)?.sync_all()?;
    Ok(())
}
#[cfg(windows)]
fn synchronize_directory(_directory: &Path) -> StoreResult<()> {
    Ok(())
}

fn parent_of(directory: &Path) -> PathBuf {
    directory.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."))
}

/// 파일부터 하위 폴더와 부모 폴더까지 디스크에 반영한다. 심볼릭 링크가 있으면 `Damaged`.
pub fn synchronize(directory: &Path) -> StoreResult<()> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let kind = fs::symlink_metadata(entry.path())?.file_type();
        if kind.is_symlink() {
            return Err(StoreError::Damaged);
        }
        if kind.is_dir() {
            synchronize(&entry.path())?;
        } else {
            // Swift `FileHandle(forUpdating:)`처럼 쓰기 권한이 필요하다.
            fs::OpenOptions::new().write(true).open(entry.path())?.sync_all()?;
        }
    }
    synchronize_directory(directory)?;
    synchronize_directory(&parent_of(directory))
}

/// 하위의 일반 파일을 난수로 덮고 비운다. 심볼릭 링크는 건드리지 않고 그 아래로도 들어가지 않는다.
fn overwrite_tree(directory: &Path) -> StoreResult<()> {
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        let kind = fs::symlink_metadata(&path)?.file_type();
        if kind.is_symlink() {
            continue;
        }
        if kind.is_dir() {
            overwrite_tree(&path)?;
            continue;
        }
        if !kind.is_file() {
            continue;
        }
        let mut file = fs::OpenOptions::new().write(true).open(&path)?;
        let meta = file.metadata()?;
        if !meta.is_file() {
            continue;
        }
        let mut remaining = meta.len();
        while remaining > 0 {
            let chunk = remaining.min(65_536) as usize;
            // 난수를 새로 뽑아 청크마다 쓴다(Swift와 같다). 난수 버퍼는 떨어질 때 0으로 덮인다.
            let data = mdemo_crypto::random(chunk)?;
            file.write_all(&data)?;
            remaining -= chunk as u64;
        }
        file.sync_all()?;
        file.set_len(0)?;
    }
    Ok(())
}

/// 안전 삭제. 시험이 실패를 주입할 수 있게 `before_removal`을 덮어쓰기와 삭제 사이에 부른다.
pub fn remove(directory: &Path, before_removal: Option<&dyn Fn(&Path) -> StoreResult<()>>) -> StoreResult<()> {
    // Swift `fileExists`처럼 링크는 따라가서 보므로, 끊어진 링크는 "없음"으로 보고 그대로 둔다.
    if !directory.exists() {
        return Ok(());
    }
    if fs::symlink_metadata(directory)?.file_type().is_symlink() {
        remove_link(directory)?;
        return synchronize_directory(&parent_of(directory));
    }
    if directory.is_dir() {
        overwrite_tree(directory)?;
    }
    if let Some(hook) = before_removal {
        hook(directory)?;
    }
    if directory.is_dir() {
        fs::remove_dir_all(directory)?;
    } else {
        fs::remove_file(directory)?;
    }
    synchronize_directory(&parent_of(directory))
}

/// 링크 자체만 지운다(가리키는 대상은 두고).
fn remove_link(path: &Path) -> StoreResult<()> {
    if path.is_dir() && cfg!(windows) {
        fs::remove_dir(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(())
}

/// 메모와 휴지통에 있는 같은 ID의 복사본을 안전 삭제한다.
pub fn remove_copies(id: &MemoID, root: &Path) -> StoreResult<()> {
    for folder in ["memos", "trash"] {
        remove(&root.join(folder).join(&id.raw_value), None)?;
    }
    Ok(())
}
