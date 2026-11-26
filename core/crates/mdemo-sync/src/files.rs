use mdemo_core::store::{modified_time, set_modified_time};
use std::{fs, path::Path};
/// 링크를 따라가지 않고 호출자가 지정한 트리만 복사한다.
pub fn copy_tree(source: &Path, destination: &Path) -> crate::Result<()> {
    if fs::symlink_metadata(source)?.file_type().is_symlink() {
        return Err("심볼릭 링크는 복사할 수 없습니다".into());
    }
    if source.is_dir() {
        fs::create_dir_all(destination)?;
        for e in fs::read_dir(source)? {
            let e = e?;
            copy_tree(&e.path(), &destination.join(e.file_name()))?;
        }
        // Swift copyItem이 보존하는 암호 메모의 백업 제외 표시를 복사 후 다시 단다.
        if fs::read_to_string(source.join("memo.md"))
            .ok()
            .and_then(|s| mdemo_core::frontmatter::decode(&s).ok())
            .is_some_and(|d| d.meta.is_locked)
        {
            mdemo_core::store::repository::exclude_from_backup(destination)?;
        }
    } else {
        fs::copy(source, destination)?;
    }
    if let Ok(date) = modified_time(source) {
        let _ = set_modified_time(destination, date);
    }
    Ok(())
}
pub fn remove(path: &Path) -> std::io::Result<()> {
    if !path.exists() {
        return Ok(());
    }
    if path.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}
/// 같은 부모의 임시 폴더로 준비한다. 실패하면 기존 폴더는 보존한다.
pub fn replace_tree(source: &Path, destination: &Path) -> crate::Result<()> {
    let parent = destination.parent().ok_or("부모 폴더 없음")?;
    fs::create_dir_all(parent)?;
    let name = destination
        .file_name()
        .ok_or("폴더 이름 없음")?
        .to_string_lossy();
    let staging = parent.join(format!(".{name}.tmp"));
    remove(&staging)?;
    copy_tree(source, &staging)?;
    let result = replace_staged(&staging, destination);
    let _ = remove(&staging);
    result
}
#[cfg(target_os = "macos")]
pub fn replace_staged(staging: &Path, destination: &Path) -> crate::Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    if !destination.exists() {
        fs::rename(staging, destination)?;
        return Ok(());
    }
    extern "C" {
        fn renamex_np(a: *const i8, b: *const i8, flags: u32) -> i32;
    }
    let a = CString::new(staging.as_os_str().as_bytes())?;
    let b = CString::new(destination.as_os_str().as_bytes())?;
    // SAFETY: 두 경로는 살아 있는 C 문자열이다. RENAME_SWAP은 폴더 이름을 원자적으로 맞바꾼다.
    if unsafe { renamex_np(a.as_ptr(), b.as_ptr(), 2) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    remove(staging)?;
    Ok(())
}
#[cfg(not(target_os = "macos"))]
pub fn replace_staged(staging: &Path, destination: &Path) -> crate::Result<()> {
    replace_staged_portable(staging, destination)
}
#[cfg(any(not(target_os = "macos"), test))]
pub fn replace_staged_portable(staging: &Path, destination: &Path) -> crate::Result<()> {
    let old = destination.with_file_name(format!(
        ".{}.old",
        destination
            .file_name()
            .ok_or("폴더 이름 없음")?
            .to_string_lossy()
    ));
    // 이전 복구본이 남아 있으면 덮어쓰지 않는다.
    if old.exists() {
        return Err("이전 폴더 복구본이 남아 있습니다".into());
    }
    let existed = destination.exists();
    if existed {
        fs::rename(destination, &old)?;
    }
    if let Err(error) = fs::rename(staging, destination) {
        if existed {
            fs::rename(&old, destination)
                .map_err(|rollback| format!("교체 실패: {error}; 되돌리기 실패: {rollback}"))?;
        }
        return Err(error.into());
    }
    if existed {
        remove(&old)?;
    }
    Ok(())
}
pub fn entries(path: &Path) -> Vec<(String, std::path::PathBuf)> {
    let mut result: Vec<_> = fs::read_dir(path)
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok())
        .map(|e| (e.file_name().to_string_lossy().into_owned(), e.path()))
        .filter(|(n, _)| !n.starts_with('.'))
        .collect();
    result.sort();
    result
}
