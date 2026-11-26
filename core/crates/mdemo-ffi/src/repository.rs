//! 실제 저장소의 레코드 경계. 파일 형식 해석은 Rust 안에서 끝낸다.
use mdemo_core::{
    frontmatter::MemoDocument,
    id::MemoID,
    link::{MemoLink, MemoLinkKind},
    meta::{MemoDate, MemoMeta},
    store::{Clock, FileMemoRepository, StoreError},
};
use mdemo_crypto::{KeyStore, LockError};
use std::sync::{Arc, Mutex};

#[derive(Debug, uniffi::Error)]
pub enum CoreRepositoryError {
    Destroyed,
    Damaged,
    Locked,
    MissingKey,
    WrongPassword,
    InvalidPassword,
    NotFound,
    Keychain { status: i32 },
    Io { message: String },
    Format { message: String },
}
impl std::fmt::Display for CoreRepositoryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for CoreRepositoryError {}
impl From<StoreError> for CoreRepositoryError {
    fn from(e: StoreError) -> Self {
        match e {
            StoreError::Destroyed => Self::Destroyed,
            StoreError::Damaged => Self::Damaged,
            StoreError::Locked => Self::Locked,
            StoreError::MissingKey => Self::MissingKey,
            StoreError::WrongPassword => Self::WrongPassword,
            StoreError::InvalidPassword => Self::InvalidPassword,
            StoreError::KeyStore(s) => Self::Keychain {
                status: s.parse().unwrap_or(-1),
            },
            StoreError::Io(e) if e.kind() == std::io::ErrorKind::NotFound => Self::NotFound,
            StoreError::Format(message) => Self::Format { message },
            e => Self::Io {
                message: e.to_string(),
            },
        }
    }
}
type Result<T> = std::result::Result<T, CoreRepositoryError>;
#[uniffi::export(with_foreign)]
pub trait CoreKeyStore: Send + Sync {
    fn read_key(&self, id: String) -> Result<Option<Vec<u8>>>;
    fn write_key(&self, id: String, bytes: Vec<u8>) -> Result<()>;
    fn delete_key(&self, id: String) -> Result<()>;
    fn read_failures(&self, id: String) -> Result<i64>;
    fn write_failures(&self, id: String, failures: i64) -> Result<()>;
    fn delete_failures(&self, id: String) -> Result<()>;
}
struct Keys(Arc<dyn CoreKeyStore>);
fn key_error(e: CoreRepositoryError) -> LockError {
    match e {
        CoreRepositoryError::Damaged => LockError::Damaged,
        CoreRepositoryError::Keychain { status } => LockError::KeyStore(status.to_string()),
        _ => LockError::KeyStore(e.to_string()),
    }
}
impl KeyStore for Keys {
    fn read_key(&self, id: &str) -> std::result::Result<Option<Vec<u8>>, LockError> {
        self.0.read_key(id.into()).map_err(key_error)
    }
    fn write_key(&self, id: &str, b: &[u8]) -> std::result::Result<(), LockError> {
        self.0.write_key(id.into(), b.into()).map_err(key_error)
    }
    fn delete_key(&self, id: &str) -> std::result::Result<(), LockError> {
        self.0.delete_key(id.into()).map_err(key_error)
    }
    fn read_failures(&self, id: &str) -> std::result::Result<i64, LockError> {
        self.0.read_failures(id.into()).map_err(key_error)
    }
    fn write_failures(&self, id: &str, n: i64) -> std::result::Result<(), LockError> {
        self.0.write_failures(id.into(), n).map_err(key_error)
    }
    fn delete_failures(&self, id: &str) -> std::result::Result<(), LockError> {
        self.0.delete_failures(id.into()).map_err(key_error)
    }
}
#[derive(uniffi::Record)]
pub struct CoreMemoLink {
    pub to: String,
    pub kind: String,
    pub label: String,
    pub unknown_suffix: String,
    pub preserves_raw_label: Option<bool>,
}
#[derive(uniffi::Record)]
pub struct CoreMemoMeta {
    pub schema_version: i64,
    pub id: String,
    pub title: Option<String>,
    pub group: Option<String>,
    pub color_hex: String,
    pub background_alpha: f64,
    pub text_alpha: f64,
    pub is_open: bool,
    pub is_pinned: bool,
    pub created: f64,
    pub modified: f64,
    pub conflict_of: Option<String>,
    pub is_locked: bool,
    pub lock_salt: Option<String>,
    pub lock_iterations: Option<i64>,
    pub lock_version: Option<i64>,
    pub lock_failures: Option<i64>,
    pub links: Vec<CoreMemoLink>,
}
impl From<MemoMeta> for CoreMemoMeta {
    fn from(m: MemoMeta) -> Self {
        Self {
            schema_version: m.schema_version,
            id: m.id.raw_value,
            title: m.title,
            group: m.group,
            color_hex: m.color_hex,
            background_alpha: m.background_alpha,
            text_alpha: m.text_alpha,
            is_open: m.is_open,
            is_pinned: m.is_pinned,
            created: m.created.0,
            modified: m.modified.0,
            conflict_of: m.conflict_of.map(|id| id.raw_value),
            is_locked: m.is_locked,
            lock_salt: m.lock_salt,
            lock_iterations: m.lock_iterations,
            lock_version: m.lock_version,
            lock_failures: m.lock_failures,
            links: m
                .links
                .into_iter()
                .map(|l| CoreMemoLink {
                    to: l.to.raw_value,
                    kind: l.kind.token().into(),
                    label: l.label,
                    unknown_suffix: l.unknown_suffix,
                    preserves_raw_label: l.preserves_raw_label,
                })
                .collect(),
        }
    }
}
impl CoreMemoMeta {
    fn native(self) -> Result<MemoMeta> {
        Ok(MemoMeta {
            schema_version: self.schema_version,
            id: MemoID::new(self.id),
            title: self.title,
            group: self.group,
            color_hex: self.color_hex,
            background_alpha: self.background_alpha,
            text_alpha: self.text_alpha,
            is_open: self.is_open,
            is_pinned: self.is_pinned,
            created: MemoDate(self.created),
            modified: MemoDate(self.modified),
            conflict_of: self.conflict_of.map(MemoID::new),
            is_locked: self.is_locked,
            lock_salt: self.lock_salt,
            lock_iterations: self.lock_iterations,
            lock_version: self.lock_version,
            lock_failures: self.lock_failures,
            links: self
                .links
                .into_iter()
                .map(|l| {
                    Ok(MemoLink {
                        to: MemoID::new(l.to),
                        kind: MemoLinkKind::ALL
                            .into_iter()
                            .find(|k| k.token() == l.kind)
                            .ok_or(CoreRepositoryError::Damaged)?,
                        label: l.label,
                        unknown_suffix: l.unknown_suffix,
                        preserves_raw_label: l.preserves_raw_label,
                    })
                })
                .collect::<Result<_>>()?,
        })
    }
}
#[derive(uniffi::Record)]
pub struct CoreMemoDocument {
    pub meta: CoreMemoMeta,
    pub body: String,
    pub unknown_frontmatter_lines: Vec<String>,
    pub unknown_link_tokens: Vec<String>,
}
impl From<MemoDocument> for CoreMemoDocument {
    fn from(d: MemoDocument) -> Self {
        Self {
            meta: d.meta.into(),
            body: d.body,
            unknown_frontmatter_lines: d.unknown_frontmatter_lines,
            unknown_link_tokens: d.unknown_link_tokens,
        }
    }
}
impl CoreMemoDocument {
    fn native(self) -> Result<MemoDocument> {
        Ok(MemoDocument {
            meta: self.meta.native()?,
            body: self.body,
            unknown_frontmatter_lines: self.unknown_frontmatter_lines,
            unknown_link_tokens: self.unknown_link_tokens,
        })
    }
}
#[derive(uniffi::Record)]
pub struct CoreMemoSummary {
    pub meta: CoreMemoMeta,
    pub preview: String,
    pub deleted_at: Option<f64>,
}
impl From<mdemo_core::store::MemoSummary> for CoreMemoSummary {
    fn from(s: mdemo_core::store::MemoSummary) -> Self {
        Self {
            meta: s.meta.into(),
            preview: s.preview,
            deleted_at: s.deleted_at.map(|d| d.0),
        }
    }
}
#[derive(uniffi::Record)]
pub struct CorePlacement {
    pub id: String,
    pub x: f64,
    pub y: f64,
}
#[derive(uniffi::Record)]
pub struct CoreBentoSpan {
    pub id: String,
    pub span: String,
}
#[derive(uniffi::Record)]
pub struct CoreBoardLayout {
    pub placements: Vec<CorePlacement>,
    pub bento_spans: Vec<CoreBentoSpan>,
    pub manual_order: Vec<String>,
}
#[derive(Default)]
struct RepositoryClock(Mutex<Option<f64>>);
impl Clock for RepositoryClock {
    fn now(&self) -> MemoDate {
        self.0
            .lock()
            .unwrap()
            .map(MemoDate)
            .unwrap_or_else(MemoDate::now)
    }
}
#[derive(uniffi::Object)]
pub struct CoreRepository {
    repository: FileMemoRepository,
    clock: Arc<RepositoryClock>,
}
#[uniffi::export]
impl CoreRepository {
    #[uniffi::constructor]
    pub fn new(root: String, keys: Arc<dyn CoreKeyStore>) -> Result<Arc<Self>> {
        let clock = Arc::new(RepositoryClock::default());
        Ok(Arc::new(Self {
            repository: FileMemoRepository::with_keys(root, clock.clone(), Arc::new(Keys(keys)))?,
            clock,
        }))
    }
    pub fn set_clock_for_testing(&self, at: f64) {
        *self.clock.0.lock().unwrap() = Some(at);
    }
    pub fn load_summaries(&self) -> Result<Vec<CoreMemoSummary>> {
        Ok(self
            .repository
            .load_summaries()?
            .into_iter()
            .map(Into::into)
            .collect())
    }
    pub fn load_trash_summaries(&self) -> Result<Vec<CoreMemoSummary>> {
        Ok(self
            .repository
            .load_trash_summaries()?
            .into_iter()
            .map(Into::into)
            .collect())
    }
    pub fn load(&self, id: String) -> Result<CoreMemoDocument> {
        Ok(self.repository.load(&MemoID::new(id))?.into())
    }
    /// 검색은 기존 Swift처럼 파기 장부와 ID 일치 검사 없이 휴지통도 읽는다.
    pub fn load_for_search(&self, id: String) -> Result<CoreMemoDocument> {
        let id = MemoID::new(id);
        let text = std::fs::read_to_string(self.repository.memo_file(&id))
            .or_else(|_| {
                std::fs::read_to_string(self.repository.trash_directory(&id).join("memo.md"))
            })
            .map_err(StoreError::from)?;
        Ok(mdemo_core::frontmatter::decode(&text)
            .map_err(StoreError::Format)?
            .into())
    }
    pub fn save(&self, document: CoreMemoDocument) -> Result<()> {
        Ok(self.repository.save(&document.native()?)?)
    }
    pub fn duplicate(&self, id: String, document: CoreMemoDocument) -> Result<()> {
        Ok(self
            .repository
            .duplicate(&MemoID::new(id), &document.native()?)?)
    }
    pub fn move_to_trash(&self, id: String) -> Result<()> {
        Ok(self.repository.move_to_trash(&MemoID::new(id))?)
    }
    pub fn restore_from_trash(&self, id: String) -> Result<()> {
        Ok(self.repository.restore_from_trash(&MemoID::new(id))?)
    }
    pub fn permanently_delete(&self, id: String) -> Result<()> {
        Ok(self.repository.permanently_delete(&MemoID::new(id))?)
    }
    pub fn empty_trash(&self, before: Option<f64>) -> Result<()> {
        Ok(self.repository.empty_trash(before.map(MemoDate))?)
    }
    pub fn attachments_directory(&self, id: String) -> String {
        self.repository
            .attachments_directory(&MemoID::new(id))
            .to_string_lossy()
            .into_owned()
    }
    pub fn prune_unused_attachments(&self, before: f64) -> u32 {
        self.repository.prune_unused_attachments(MemoDate(before)) as u32
    }
    pub fn load_groups(&self) -> Vec<String> {
        self.repository.load_groups()
    }
    pub fn save_groups(&self, groups: Vec<String>) -> Result<()> {
        Ok(self.repository.save_groups(&groups)?)
    }
    pub fn destroyed(&self) -> Result<Vec<String>> {
        Ok(self.repository.destroyed()?.into_iter().collect())
    }
    pub fn local_only(&self) -> Result<Vec<String>> {
        Ok(
            mdemo_core::ledger::read(&self.repository.root().join("local-only.json"))
                .map_err(StoreError::from)?
                .into_iter()
                .collect(),
        )
    }
    pub fn load_board_layout(&self) -> CoreBoardLayout {
        let b = self.repository.load_board_layout();
        CoreBoardLayout {
            placements: b
                .placements
                .into_iter()
                .map(|(id, p)| CorePlacement { id, x: p.x, y: p.y })
                .collect(),
            bento_spans: b
                .bento_spans
                .into_iter()
                .map(|(id, s)| CoreBentoSpan {
                    id,
                    span: serde_json::to_value(s).unwrap().as_str().unwrap().into(),
                })
                .collect(),
            manual_order: b.manual_order.into_iter().map(|id| id.raw_value).collect(),
        }
    }
    pub fn save_board_layout(&self, layout: CoreBoardLayout) -> Result<()> {
        use mdemo_core::board_layout::{BoardLayout, Placement};
        let b = BoardLayout {
            placements: layout
                .placements
                .into_iter()
                .map(|p| (p.id, Placement { x: p.x, y: p.y }))
                .collect(),
            bento_spans: layout
                .bento_spans
                .into_iter()
                .map(|s| {
                    Ok((
                        s.id,
                        serde_json::from_value(serde_json::Value::String(s.span))
                            .map_err(StoreError::from)?,
                    ))
                })
                .collect::<Result<_>>()?,
            manual_order: layout.manual_order.into_iter().map(MemoID::new).collect(),
        };
        Ok(self.repository.save_board_layout(&b)?)
    }
}
