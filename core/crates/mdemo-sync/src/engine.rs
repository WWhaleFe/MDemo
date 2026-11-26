//! Swift SyncService의 판단 순서와 쓰기 직전 지문 검사를 보존한다.
use crate::{files, state::SyncState, Result};
use mdemo_core::{
    frontmatter::{self, MemoDocument},
    groups,
    id::MemoID,
    ledger,
    meta::MemoDate,
    store::{
        atomic_write, modified_time, secure_delete, set_modified_time, Clock, FileMemoRepository,
        IdSource, SystemClock, SystemIds,
    },
};
use mdemo_crypto::{KeyStore, MemoryKeyStore};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum SyncMode {
    Both,
    Push,
    Pull,
}
#[derive(Default, Debug)]
pub struct SyncReport {
    pub pushed: usize,
    pub pulled: usize,
    pub conflicts: usize,
    pub deletions: usize,
    pub unreadable: usize,
    pub locked_local: usize,
    pub removed_local_only: usize,
    pub conflict_copies: Vec<MemoID>,
}
impl SyncReport {
    pub fn is_empty(&self) -> bool {
        self.pushed == 0
            && self.pulled == 0
            && self.conflicts == 0
            && self.deletions == 0
            && self.unreadable == 0
            && self.removed_local_only == 0
    }
    pub fn summary(&self) -> String {
        if self.is_empty() && self.locked_local == 0 {
            return "변경 없음".into();
        }
        let mut parts = Vec::new();
        for (name, n) in [
            ("올림", self.pushed),
            ("내려받음", self.pulled),
            ("삭제 반영", self.deletions),
            ("충돌 사본", self.conflicts),
            ("읽지 못한 파일", self.unreadable),
        ] {
            if n > 0 {
                parts.push(format!("{name} {n}"));
            }
        }
        if self.locked_local > 0 {
            parts.push(format!(
                "잠긴 메모 {}개는 이 맥에만 있습니다",
                self.locked_local
            ));
        }
        if self.removed_local_only > 0 {
            parts.push(format!(
                "다른 맥에서 잠근 메모 {}개를 이 맥에서 지웠습니다",
                self.removed_local_only
            ));
        }
        parts.join(" · ")
    }
}
#[derive(Clone)]
struct Entry {
    modified: MemoDate,
    trash: bool,
    hash: String,
    file_modified: Option<MemoDate>,
    external: bool,
}
#[derive(Debug)]
struct Skip;
impl std::fmt::Display for Skip {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("훑은 뒤 변경됨")
    }
}
impl std::error::Error for Skip {}
pub struct SyncService {
    pub local_root: PathBuf,
    pub remote_root: PathBuf,
    pub state_url: PathBuf,
    pub keys: Arc<dyn KeyStore>,
    pub clock: Arc<dyn Clock>,
    pub ids: Arc<dyn IdSource>,
    pub after_scan: Option<Box<dyn Fn() + Send + Sync>>,
}
pub fn same_moment(a: Option<MemoDate>, b: Option<MemoDate>) -> bool {
    a.zip(b)
        .is_some_and(|(a, b)| ((a.0 + 978_307_200.) - (b.0 + 978_307_200.)).abs() < 0.0005)
}
pub fn external_edit(date: MemoDate, last: Option<MemoDate>, has_hashes: bool) -> bool {
    has_hashes && last.is_some_and(|last| date.0 + 978_307_200. <= last.0 + 978_307_200. + 0.0005)
}
fn changed(e: &Entry, date: Option<MemoDate>, hashes: Option<&Vec<String>>) -> bool {
    hashes.map_or_else(
        || !same_moment(Some(e.modified), date),
        |h| !h.contains(&e.hash),
    )
}
pub fn fingerprint(path: &Path) -> Option<String> {
    fs::read(path).ok().map(|b| {
        mdemo_crypto::sha256(&b)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    })
}
fn directory(root: &Path, id: &str, trash: bool) -> PathBuf {
    root.join(if trash { "trash" } else { "memos" }).join(id)
}
fn read(root: &Path, id: &str, trash: bool) -> Result<MemoDocument> {
    Ok(frontmatter::decode(&fs::read_to_string(
        directory(root, id, trash).join("memo.md"),
    )?)
    .map_err(|e| format!("앞머리: {e}"))?)
}
fn write(root: &Path, trash: bool, doc: &MemoDocument) -> Result<()> {
    atomic_write(
        &directory(root, &doc.meta.id.raw_value, trash).join("memo.md"),
        frontmatter::encode(doc).as_bytes(),
    )?;
    Ok(())
}
fn scan(root: &Path) -> (BTreeMap<String, Entry>, BTreeSet<String>) {
    let mut result = BTreeMap::new();
    let mut unreadable = BTreeSet::new();
    for trash in [false, true] {
        for (id, path) in files::entries(&root.join(if trash { "trash" } else { "memos" })) {
            if !MemoID::new(&id).is_valid() || !path.join("memo.md").exists() {
                continue;
            }
            let Ok(bytes) = fs::read(path.join("memo.md")) else {
                unreadable.insert(id);
                continue;
            };
            let Some(doc) = std::str::from_utf8(&bytes)
                .ok()
                .and_then(|s| frontmatter::decode(s).ok())
            else {
                unreadable.insert(id);
                continue;
            };
            if doc.meta.is_locked {
                continue;
            }
            let hash = mdemo_crypto::sha256(&bytes)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            result.insert(
                id,
                Entry {
                    modified: doc.meta.modified,
                    trash,
                    hash,
                    file_modified: modified_time(&path.join("memo.md")).ok(),
                    external: false,
                },
            );
        }
    }
    (result, unreadable)
}
fn expect(root: &Path, id: &str, trash: bool, hash: Option<&str>) -> Result<()> {
    if fingerprint(&directory(root, id, trash).join("memo.md")).as_deref() != hash {
        return Err(Box::new(Skip));
    }
    Ok(())
}
impl SyncService {
    pub fn new(
        local: impl Into<PathBuf>,
        remote: impl Into<PathBuf>,
        state: impl Into<PathBuf>,
    ) -> Self {
        Self {
            local_root: local.into(),
            remote_root: remote.into(),
            state_url: state.into(),
            keys: Arc::new(MemoryKeyStore::default()),
            clock: Arc::new(SystemClock),
            ids: Arc::new(SystemIds),
            after_scan: None,
        }
    }
    fn prepare(&self) -> Result<()> {
        for root in [&self.local_root, &self.remote_root] {
            for folder in ["memos", "trash"] {
                fs::create_dir_all(root.join(folder))?;
            }
        }
        Ok(())
    }
    fn privacy(&self, report: &mut SyncReport) -> Result<BTreeSet<String>> {
        let mut destroyed = ledger::read(&self.local_root.join("destroyed.json"))?;
        destroyed.extend(ledger::read(&self.remote_root.join("destroyed.json"))?);
        let mut only = ledger::read(&self.local_root.join("local-only.json"))?;
        only.extend(ledger::read(&self.remote_root.join("local-only.json"))?);
        let repo =
            FileMemoRepository::with_keys(&self.local_root, self.clock.clone(), self.keys.clone())?;
        let locked_list: Vec<_> = repo
            .load_summaries()?
            .into_iter()
            .chain(repo.load_trash_summaries()?)
            .filter(|s| s.meta.is_locked)
            .map(|s| s.meta.id.raw_value)
            .collect();
        report.locked_local = locked_list.len();
        let locked: BTreeSet<_> = locked_list.into_iter().collect();
        only.extend(locked.iter().cloned());
        for root in [&self.local_root, &self.remote_root] {
            ledger::write(&root.join("destroyed.json"), &destroyed)?;
            ledger::write(&root.join("local-only.json"), &only)?;
        }
        let excluded: BTreeSet<_> = destroyed.union(&only).cloned().collect();
        for raw in &excluded {
            let id = MemoID::new(raw);
            secure_delete::remove_copies(&id, &self.remote_root)?;
            if destroyed.contains(raw) || !locked.contains(raw) {
                let exists = [false, true]
                    .iter()
                    .any(|t| directory(&self.local_root, raw, *t).exists());
                if destroyed.contains(raw) {
                    self.keys.delete(raw)?;
                }
                secure_delete::remove_copies(&id, &self.local_root)?;
                if exists {
                    if destroyed.contains(raw) {
                        report.deletions += 1;
                    } else {
                        report.removed_local_only += 1;
                    }
                }
            }
        }
        Ok(excluded)
    }
    pub fn enforce_privacy(&self) -> Result<SyncReport> {
        self.prepare()?;
        let mut report = SyncReport::default();
        self.privacy(&mut report)?;
        Ok(report)
    }
    pub fn sync(&self, mode: SyncMode) -> Result<SyncReport> {
        self.prepare()?;
        let mut state = SyncState::load(&self.state_url);
        let mut report = SyncReport::default();
        let excluded = self.privacy(&mut report)?;
        for id in &excluded {
            state.forget(id);
        }
        let (local, mut skipped) = scan(&self.local_root);
        let (remote, unreadable) = scan(&self.remote_root);
        skipped.extend(unreadable);
        report.unreadable = skipped.len();
        if let Some(hook) = &self.after_scan {
            hook();
        }
        let all: BTreeSet<_> = local.keys().chain(remote.keys()).cloned().collect();
        for id in all {
            if skipped.contains(&id) || excluded.contains(&id) {
                continue;
            }
            if let Err(e) = self.reconcile(
                &id,
                local.get(&id).cloned(),
                remote.get(&id).cloned(),
                mode,
                &mut state,
                &mut report,
            ) {
                if !e.is::<Skip>() {
                    return Err(e);
                }
            }
        }
        if mode != SyncMode::Pull {
            let (fresh, _) = scan(&self.local_root);
            for id in report.conflict_copies.clone() {
                if let Some(entry) = fresh.get(&id.raw_value) {
                    let _ = self.reconcile(
                        &id.raw_value,
                        Some(entry.clone()),
                        None,
                        mode,
                        &mut state,
                        &mut report,
                    );
                }
            }
        }
        self.groups(mode)?;
        self.board(mode, &mut state)?;
        state.save(&self.state_url);
        Ok(report)
    }
    fn transfer(
        &self,
        id: &str,
        source: &Path,
        dest: &Path,
        mut e: Entry,
        existing: Option<&Entry>,
        state: &mut SyncState,
    ) -> Result<()> {
        expect(source, id, e.trash, Some(&e.hash))?;
        for trash in [false, true] {
            expect(
                dest,
                id,
                trash,
                existing
                    .filter(|x| x.trash == trash)
                    .map(|x| x.hash.as_str()),
            )?;
        }
        if e.external && source == self.local_root {
            let mut doc = read(source, id, e.trash)?;
            doc.meta.modified = e.modified;
            write(source, e.trash, &doc)?;
            e.hash = fingerprint(&directory(source, id, e.trash).join("memo.md"))
                .ok_or("지문 읽기 실패")?;
            e.external = false;
        }
        files::replace_tree(
            &directory(source, id, e.trash),
            &directory(dest, id, e.trash),
        )?;
        if e.external {
            let mut doc = read(dest, id, e.trash)?;
            doc.meta.modified = e.modified;
            write(dest, e.trash, &doc)?;
        }
        let mut hashes = vec![e.hash];
        if let Some(h) = fingerprint(&directory(dest, id, e.trash).join("memo.md")) {
            hashes.push(h);
        }
        state.record(id, e.modified, hashes);
        Ok(())
    }
    fn conflict_copy(
        &self,
        id: &str,
        root: &Path,
        e: &Entry,
        report: &mut SyncReport,
    ) -> Result<()> {
        let Ok(mut doc) = read(root, id, e.trash) else {
            return Ok(());
        };
        let new = self.ids.next_id(self.clock.now());
        doc.meta.id = new.clone();
        doc.meta.conflict_of = Some(MemoID::new(id));
        let dest = directory(&self.local_root, &new.raw_value, false);
        if dest.exists() {
            return Err("충돌 사본 ID가 이미 있습니다".into());
        }
        let staging = dest.with_file_name(format!(".{}.tmp", new.raw_value));
        files::remove(&staging)?;
        files::copy_tree(&directory(root, id, e.trash), &staging)?;
        atomic_write(
            &staging.join("memo.md"),
            frontmatter::encode(&doc).as_bytes(),
        )?;
        fs::rename(staging, dest)?;
        report.conflicts += 1;
        report.conflict_copies.push(new);
        Ok(())
    }
    fn conflict(
        &self,
        id: &str,
        l: Entry,
        r: Entry,
        mode: SyncMode,
        state: &mut SyncState,
        report: &mut SyncReport,
    ) -> Result<()> {
        let newer = r.modified > l.modified
            || (same_moment(Some(r.modified), Some(l.modified))
                && r.file_modified > l.file_modified);
        if (newer && mode == SyncMode::Push) || (!newer && mode == SyncMode::Pull) {
            return Ok(());
        }
        expect(&self.local_root, id, l.trash, Some(&l.hash))?;
        expect(&self.remote_root, id, r.trash, Some(&r.hash))?;
        if newer {
            self.conflict_copy(id, &self.local_root, &l, report)?;
            self.transfer(id, &self.remote_root, &self.local_root, r, Some(&l), state)?;
            report.pulled += 1;
        } else {
            self.conflict_copy(id, &self.remote_root, &r, report)?;
            self.transfer(id, &self.local_root, &self.remote_root, l, Some(&r), state)?;
            report.pushed += 1;
        }
        Ok(())
    }
    fn reconcile(
        &self,
        id: &str,
        l: Option<Entry>,
        r: Option<Entry>,
        mode: SyncMode,
        state: &mut SyncState,
        report: &mut SyncReport,
    ) -> Result<()> {
        let last = state.dates.get(id).copied();
        let hashes = state.hashes.get(id).cloned();
        match (l, r) {
            (None, None) => state.forget(id),
            (Some(l), None) => {
                if mode != SyncMode::Pull {
                    self.transfer(id, &self.local_root, &self.remote_root, l, None, state)?;
                    report.pushed += 1;
                }
            }
            (None, Some(r)) => {
                if mode != SyncMode::Push {
                    self.transfer(id, &self.remote_root, &self.local_root, r, None, state)?;
                    report.pulled += 1;
                }
            }
            (Some(mut l), Some(mut r)) => {
                if l.trash != r.trash {
                    if (l.trash && mode == SyncMode::Pull) || (r.trash && mode == SyncMode::Push) {
                        return Ok(());
                    }
                    let (active, root, trashed) = if l.trash {
                        (&r, &self.remote_root, &l)
                    } else {
                        (&l, &self.local_root, &r)
                    };
                    expect(root, id, false, Some(&active.hash))?;
                    if changed(active, last, hashes.as_ref()) && active.hash != trashed.hash {
                        self.conflict_copy(id, root, active, report)?;
                    }
                    if l.trash {
                        self.transfer(id, &self.local_root, &self.remote_root, l, Some(&r), state)?;
                        files::remove(&directory(&self.remote_root, id, false))?;
                    } else {
                        self.transfer(id, &self.remote_root, &self.local_root, r, Some(&l), state)?;
                        files::remove(&directory(&self.local_root, id, false))?;
                    }
                    report.deletions += 1;
                    return Ok(());
                }
                let lc = changed(&l, last, hashes.as_ref());
                let rc = changed(&r, last, hashes.as_ref());
                l.external = lc && external_edit(l.modified, last, hashes.is_some());
                r.external = rc && external_edit(r.modified, last, hashes.is_some());
                if l.external {
                    l.modified = l.file_modified.unwrap_or_else(|| self.clock.now());
                }
                if r.external {
                    r.modified = r.file_modified.unwrap_or_else(|| self.clock.now());
                }
                if (lc || rc) && l.hash == r.hash {
                    state.record(id, l.modified, vec![l.hash, r.hash]);
                    return Ok(());
                }
                if hashes.is_none() && !lc && !rc {
                    if l.hash == r.hash {
                        state.record(id, last.unwrap_or(l.modified), vec![l.hash, r.hash]);
                    } else {
                        self.conflict(id, l, r, mode, state, report)?;
                    }
                    return Ok(());
                }
                match (lc, rc) {
                    (true, false) if mode != SyncMode::Pull => {
                        self.transfer(id, &self.local_root, &self.remote_root, l, Some(&r), state)?;
                        report.pushed += 1;
                    }
                    (false, true) if mode != SyncMode::Push => {
                        self.transfer(id, &self.remote_root, &self.local_root, r, Some(&l), state)?;
                        report.pulled += 1;
                    }
                    (true, true) => self.conflict(id, l, r, mode, state, report)?,
                    _ => (),
                }
            }
        }
        Ok(())
    }
    fn groups(&self, mode: SyncMode) -> Result<()> {
        let load = |r: &Path| {
            fs::read(r.join("groups.json"))
                .map(|b| groups::decode(&b))
                .unwrap_or_default()
        };
        let mut l = load(&self.local_root);
        let r = load(&self.remote_root);
        if l == r {
            return Ok(());
        }
        for g in r {
            if !l.iter().any(|x| mdemo_core::nfd(x) == mdemo_core::nfd(&g)) {
                l.push(g);
            }
        }
        let bytes = groups::encode(&l)?;
        if mode != SyncMode::Pull {
            atomic_write(&self.remote_root.join("groups.json"), &bytes)?;
        }
        if mode != SyncMode::Push {
            atomic_write(&self.local_root.join("groups.json"), &bytes)?;
        }
        Ok(())
    }
    fn board(&self, mode: SyncMode, state: &mut SyncState) -> Result<()> {
        let l = self.local_root.join("board.json");
        let r = self.remote_root.join("board.json");
        let ld = modified_time(&l).ok();
        let rd = modified_time(&r).ok();
        let (src, dst, date) = match (ld, rd) {
            (Some(a), Some(b)) if a == b => {
                state.dates.insert("board.json".into(), a);
                return Ok(());
            }
            (Some(a), b) if b.is_none_or(|b| a > b) => {
                if mode == SyncMode::Pull {
                    return Ok(());
                }
                (l, r, a)
            }
            (_, Some(b)) => {
                if mode == SyncMode::Push {
                    return Ok(());
                }
                (r, l, b)
            }
            _ => return Ok(()),
        };
        atomic_write(&dst, &fs::read(src)?)?;
        set_modified_time(&dst, date)?;
        state.dates.insert("board.json".into(), date);
        Ok(())
    }
}
