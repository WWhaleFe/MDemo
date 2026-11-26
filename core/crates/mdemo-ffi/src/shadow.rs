//! 복제본에서만 쓰는 그림자 저장소 경계. 오류에는 경로나 본문을 넣지 않는다.
use mdemo_core::{
    frontmatter::{self, MemoDocument},
    id::MemoID,
    meta::MemoDate,
    store::{FileMemoRepository, ManualClock},
};
use sha2::{Digest, Sha256};
use std::{fs, io::Read, path::Path, sync::Arc};

#[derive(Debug, uniffi::Error)]
pub enum ShadowError {
    Failed,
}
impl std::fmt::Display for ShadowError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("그림자 처리 실패")
    }
}
impl std::error::Error for ShadowError {}
type Result<T> = std::result::Result<T, ShadowError>;
fn safe<T, E>(v: std::result::Result<T, E>) -> Result<T> {
    v.map_err(|_| ShadowError::Failed)
}
fn hash(bytes: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(bytes.as_ref()))
}
fn file_hash(path: &Path) -> Result<String> {
    let mut file = safe(fs::File::open(path))?;
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = safe(file.read(&mut buffer))?;
        if n == 0 {
            break;
        }
        digest.update(&buffer[..n]);
    }
    Ok(format!("{:x}", digest.finalize()))
}
fn valid_id(value: &str) -> Result<()> {
    if MemoID::new(value).is_valid() {
        Ok(())
    } else {
        Err(ShadowError::Failed)
    }
}

#[derive(Clone, uniffi::Record)]
pub struct ShadowEntry {
    pub path: String,
    pub size: u64,
    pub sha256: String,
    pub mtime: f64,
}
#[derive(uniffi::Record)]
pub struct ShadowSummary {
    pub id: String,
    pub digest: String,
}
#[derive(uniffi::Enum)]
pub enum ShadowOp {
    Save {
        memo_text: String,
    },
    Duplicate {
        source_id: String,
        memo_text: String,
    },
    MoveToTrash {
        id: String,
        at: f64,
    },
    Restore {
        id: String,
    },
    PermanentlyDelete {
        id: String,
        at: f64,
    },
    EmptyTrash {
        before: Option<f64>,
        at: f64,
    },
    SaveGroups {
        json: String,
    },
    SaveBoard {
        json: String,
    },
}

#[uniffi::export]
pub fn shadow_tree_digest(dir: String) -> Result<Vec<ShadowEntry>> {
    fn walk(root: &Path, p: &Path, out: &mut Vec<ShadowEntry>) -> Result<()> {
        let m = safe(fs::symlink_metadata(p))?;
        let rel = safe(p.strip_prefix(root))?
            .to_string_lossy()
            .replace('\\', "/");
        let t = safe(m.modified())?;
        let unix = match t.duration_since(std::time::UNIX_EPOCH) {
            Ok(d) => d.as_secs_f64(),
            Err(e) => -e.duration().as_secs_f64(),
        };
        let (path, size, sha256) = if m.file_type().is_symlink() {
            (rel, 0, "link".into())
        } else if m.is_dir() {
            (format!("dir:{rel}"), 0, String::new())
        } else if m.is_file() {
            (rel, m.len(), file_hash(p)?)
        } else {
            return Ok(());
        };
        out.push(ShadowEntry {
            path,
            size,
            sha256,
            mtime: unix - 978307200.,
        });
        if m.is_dir() {
            for e in safe(fs::read_dir(p))? {
                walk(root, &safe(e)?.path(), out)?;
            }
        }
        Ok(())
    }
    let mut out = vec![];
    walk(Path::new(&dir), Path::new(&dir), &mut out)?;
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(out)
}
#[uniffi::export]
pub fn shadow_load_digest(root: String, id: String) -> Result<String> {
    valid_id(&id)?;
    let doc = safe(FileMemoRepository::read_only(root).load(&MemoID::new(id)))?;
    if doc.meta.is_locked {
        return Err(ShadowError::Failed);
    }
    Ok(hash(frontmatter::encode(&doc)))
}
fn summaries(root: String, trash: bool) -> Result<Vec<ShadowSummary>> {
    let repo = FileMemoRepository::read_only(root);
    let list = safe(if trash {
        repo.load_trash_summaries()
    } else {
        repo.load_summaries()
    })?;
    Ok(list
        .into_iter()
        .filter(|s| !s.meta.is_locked)
        .map(|s| {
            let id = s.meta.id.raw_value.clone();
            let meta = frontmatter::encode(&MemoDocument {
                meta: s.meta,
                body: String::new(),
                unknown_frontmatter_lines: vec![],
                unknown_link_tokens: vec![],
            });
            let date = s.deleted_at.map(|d| swift_double(d.0)).unwrap_or_default();
            ShadowSummary {
                id,
                digest: hash(format!("{meta}\0{}\0{date}", s.preview)),
            }
        })
        .collect())
}
fn swift_double(v: f64) -> String {
    let mut s = mdemo_core::json::double(v);
    if !s.contains('.') && !s.contains('e') {
        s.push_str(".0");
    }
    s
}
#[uniffi::export]
pub fn shadow_summaries(root: String) -> Result<Vec<ShadowSummary>> {
    summaries(root, false)
}
#[uniffi::export]
pub fn shadow_trash_summaries(root: String) -> Result<Vec<ShadowSummary>> {
    summaries(root, true)
}
fn copy_tree(a: &Path, b: &Path) -> Result<()> {
    let m = safe(fs::symlink_metadata(a))?;
    if m.file_type().is_symlink() {
        return Err(ShadowError::Failed);
    }
    if m.is_dir() {
        safe(fs::create_dir(b))?;
        for e in safe(fs::read_dir(a))? {
            let e = safe(e)?;
            copy_tree(&e.path(), &b.join(e.file_name()))?;
        }
    } else {
        safe(fs::copy(a, b))?;
    }
    safe(mdemo_core::store::set_modified_time(
        b,
        safe(mdemo_core::store::modified_time(a))?,
    ))?;
    Ok(())
}
#[uniffi::export]
pub fn shadow_apply(work_root: String, op: ShadowOp) -> Result<()> {
    match &op {
        ShadowOp::Duplicate { source_id, .. } => valid_id(source_id)?,
        ShadowOp::MoveToTrash { id, .. }
        | ShadowOp::Restore { id }
        | ShadowOp::PermanentlyDelete { id, .. } => valid_id(id)?,
        _ => {}
    }
    let at = match &op {
        ShadowOp::MoveToTrash { at, .. }
        | ShadowOp::PermanentlyDelete { at, .. }
        | ShadowOp::EmptyTrash { at, .. } => *at,
        _ => 0.,
    };
    if !at.is_finite() {
        return Err(ShadowError::Failed);
    }
    let repo = safe(FileMemoRepository::new(
        work_root,
        Arc::new(ManualClock::new(MemoDate(at))),
    ))?;
    match op {
        ShadowOp::Save { memo_text } => {
            let d = safe(frontmatter::decode(&memo_text))?;
            if d.meta.is_locked {
                return Err(ShadowError::Failed);
            }
            safe(repo.save(&d))
        }
        ShadowOp::Duplicate {
            source_id,
            memo_text,
        } => {
            let d = safe(frontmatter::decode(&memo_text))?;
            let source = MemoID::new(source_id);
            if d.meta.is_locked || safe(repo.load(&source))?.meta.is_locked {
                return Err(ShadowError::Failed);
            }
            let dest = repo.memo_directory(&d.meta.id);
            copy_tree(&repo.memo_directory(&source), &dest)?;
            safe(repo.save(&d))
        }
        ShadowOp::MoveToTrash { id, .. } => safe(repo.move_to_trash(&MemoID::new(id))),
        ShadowOp::Restore { id } => safe(repo.restore_from_trash(&MemoID::new(id))),
        ShadowOp::PermanentlyDelete { id, .. } => safe(repo.permanently_delete(&MemoID::new(id))),
        ShadowOp::EmptyTrash { before, .. } => safe(repo.empty_trash(before.map(MemoDate))),
        ShadowOp::SaveGroups { json } => {
            safe(repo.save_groups(&safe(serde_json::from_str::<Vec<String>>(&json))?))
        }
        ShadowOp::SaveBoard { json } => {
            safe(repo.save_board_layout(&safe(serde_json::from_str(&json))?))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn temp() -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "mdemo-shadow-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }
    #[test]
    fn reads_never_create_repository_directories() {
        let root = temp();
        assert!(shadow_summaries(root.to_string_lossy().into())
            .unwrap()
            .is_empty());
        assert!(shadow_trash_summaries(root.to_string_lossy().into())
            .unwrap()
            .is_empty());
        assert!(fs::read_dir(&root).unwrap().next().is_none());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn tree_includes_hidden_directories_and_does_not_follow_links() {
        let root = temp();
        fs::create_dir(root.join(".hidden")).unwrap();
        fs::write(root.join(".hidden/file"), b"abc").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("/unreadable-target", root.join("link")).unwrap();
        let tree = shadow_tree_digest(root.to_string_lossy().into()).unwrap();
        assert!(tree.windows(2).all(|w| w[0].path < w[1].path));
        assert!(tree.iter().any(|e| e.path == "dir:.hidden"));
        assert!(tree
            .iter()
            .any(|e| e.path == ".hidden/file" && e.sha256 == hash(b"abc") && e.size == 3));
        #[cfg(unix)]
        assert!(tree.iter().any(|e| e.path == "link" && e.sha256 == "link"));
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn summary_date_matches_swift_double_convention() {
        assert_eq!(swift_double(0.), "0.0");
        assert_eq!(swift_double(800000000.125), "800000000.125");
        assert_eq!(swift_double(1e-5), "1e-05");
    }
}
