//! 안전 삭제 (Swift `SecureMemoDeletion`). 같은 길이의 난수로 덮고 동기화한 뒤 지운다.
//!
//! APFS 스냅샷, SSD의 물리 블록, Windows의 NTFS 로그까지 지웠다고 보장하지는 않는다(Swift와 같다).
//! Swift처럼 `O_NOFOLLOW`로 열어 심볼릭 링크를 따라가지 않는다(확인과 열기 사이 경쟁을 커널이 막는다,
//! 2026-11-26 Gemini 교차 검수 지적 반영). 열 때 링크로 바뀌어 있으면 ELOOP으로 실패하고, 덮어쓰기는 그 항목을 건너뛴다.
//! Windows는 P8에서 FILE_FLAG_OPEN_REPARSE_POINT로 같은 규칙을 정한다.

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

/// 링크를 따라가지 않고 쓰기용으로 연다(Swift `open(O_WRONLY | O_NOFOLLOW)`).
fn open_no_follow(path: &Path) -> std::io::Result<fs::File> {
    let mut options = fs::OpenOptions::new();
    options.write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        #[cfg(target_os = "macos")]
        const O_NOFOLLOW: i32 = 0x0100;
        #[cfg(not(target_os = "macos"))]
        const O_NOFOLLOW: i32 = 0o400000;
        options.custom_flags(O_NOFOLLOW);
    }
    options.open(path)
}

/// 일반 파일 하나를 같은 길이의 난수로 덮고 동기화한 뒤 비운다. 열 때 링크였으면 건드리지 않는다.
fn overwrite_file(path: &Path) -> StoreResult<()> {
    let mut file = match open_no_follow(path) {
        Ok(file) => file,
        Err(error) if fs::symlink_metadata(path).map(|m| m.file_type().is_symlink()).unwrap_or(false) => {
            let _ = error;
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    };
    let meta = file.metadata()?;
    if !meta.is_file() {
        return Ok(());
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
            open_no_follow(&entry.path()).map_err(|_| StoreError::Damaged)?.sync_all()?;
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
        overwrite_file(&path)?;
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
    } else {
        // 폴더가 아닌 파일 하나가 와도 덮어쓴 뒤 지운다(Gemini 교차 검수 지적).
        overwrite_file(directory)?;
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mdemo-secure-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn 링크가_가리키는_바깥_파일은_덮어쓰지_않는다() {
        let root = temp("link");
        let outside = root.join("outside.txt");
        fs::write(&outside, b"keep me").unwrap();
        let memo = root.join("memo");
        fs::create_dir_all(&memo).unwrap();
        fs::write(memo.join("memo.md"), b"secret").unwrap();
        std::os::unix::fs::symlink(&outside, memo.join("link.md")).unwrap();
        remove(&memo, None).unwrap();
        assert!(!memo.exists());
        assert_eq!(fs::read(&outside).unwrap(), b"keep me");
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn 폴더가_아닌_파일도_덮어쓴_뒤_지운다() {
        let root = temp("file");
        let file = root.join("plain.enc");
        fs::write(&file, b"secret-bytes").unwrap();
        let seen = std::cell::RefCell::new(Vec::new());
        let hook = |p: &Path| -> StoreResult<()> {
            seen.borrow_mut().push(fs::read(p).unwrap());
            Ok(())
        };
        remove(&file, Some(&hook)).unwrap();
        assert!(!file.exists());
        // 지우기 직전에는 이미 비워져 있어야 한다(덮어쓴 뒤 길이 0).
        assert_eq!(seen.borrow()[0], Vec::<u8>::new());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn 열_때_링크면_건너뛴다() {
        let root = temp("open");
        let target = root.join("target");
        fs::write(&target, b"x").unwrap();
        let link = root.join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(open_no_follow(&link).is_err());
        overwrite_file(&link).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"x");
        fs::remove_dir_all(&root).unwrap();
    }
}
