//! 동기화 정책은 Rust, 통신과 키체인은 플랫폼 콜백에 둔다.
use crate::repository::{CoreKeyStore, Keys};
use mdemo_sync::{DriveApi, DriveError, DriveFile, SyncMode, SyncReport, SyncService};
use std::sync::Arc;

#[derive(Debug, uniffi::Error)]
pub enum CoreSyncError {
    Io { message: String },
    Drive { error: CoreDriveError },
}
impl std::fmt::Display for CoreSyncError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for CoreSyncError {}
fn error(e: Box<dyn std::error::Error>) -> CoreSyncError {
    match e.downcast::<DriveError>() {
        Ok(e) => CoreSyncError::Drive { error: (*e).into() },
        Err(e) => CoreSyncError::Io {
            message: e.to_string(),
        },
    }
}
#[derive(Debug, uniffi::Error)]
pub enum CoreDriveError {
    NotFound,
    Http { status: i32, message: String },
    InvalidResponse,
    Incomplete { count: u64 },
}
impl std::fmt::Display for CoreDriveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for CoreDriveError {}
impl From<DriveError> for CoreDriveError {
    fn from(e: DriveError) -> Self {
        match e {
            DriveError::NotFound => Self::NotFound,
            DriveError::InvalidResponse => Self::InvalidResponse,
            DriveError::Http(status, message) => Self::Http { status, message },
            DriveError::Incomplete(n) => Self::Incomplete { count: n as u64 },
        }
    }
}
impl From<CoreDriveError> for DriveError {
    fn from(e: CoreDriveError) -> Self {
        match e {
            CoreDriveError::NotFound => Self::NotFound,
            CoreDriveError::InvalidResponse => Self::InvalidResponse,
            CoreDriveError::Http { status, message } => Self::Http(status, message),
            CoreDriveError::Incomplete { count } => Self::Incomplete(count as usize),
        }
    }
}
#[derive(uniffi::Record)]
pub struct CoreDriveFile {
    pub id: String,
    pub name: String,
    pub mime_type: String,
    pub md5: Option<String>,
    pub parents: Vec<String>,
    pub modified_time: Option<f64>,
}
impl From<CoreDriveFile> for DriveFile {
    fn from(f: CoreDriveFile) -> Self {
        Self {
            id: f.id,
            name: f.name,
            mime_type: f.mime_type,
            md5: f.md5,
            parents: f.parents,
            modified_time: f.modified_time.map(mdemo_core::meta::MemoDate),
        }
    }
}
#[uniffi::export(with_foreign)]
pub trait CoreDriveApi: Send + Sync {
    fn list(&self) -> Result<Vec<CoreDriveFile>, CoreDriveError>;
    fn download(&self, id: String) -> Result<Vec<u8>, CoreDriveError>;
    fn upload(
        &self,
        name: String,
        parent_id: Option<String>,
        data: Vec<u8>,
    ) -> Result<CoreDriveFile, CoreDriveError>;
    fn update(&self, id: String, data: Vec<u8>) -> Result<CoreDriveFile, CoreDriveError>;
    fn create_folder(
        &self,
        name: String,
        parent_id: Option<String>,
    ) -> Result<CoreDriveFile, CoreDriveError>;
    fn delete(&self, id: String) -> Result<(), CoreDriveError>;
}
struct Drive(Arc<dyn CoreDriveApi>);
impl DriveApi for Drive {
    fn list(&mut self) -> Result<Vec<DriveFile>, DriveError> {
        self.0
            .list()
            .map(|v| v.into_iter().map(Into::into).collect())
            .map_err(Into::into)
    }
    fn download(&mut self, id: &str) -> Result<Vec<u8>, DriveError> {
        self.0.download(id.into()).map_err(Into::into)
    }
    fn upload(
        &mut self,
        name: &str,
        parent: Option<&str>,
        data: &[u8],
    ) -> Result<DriveFile, DriveError> {
        self.0
            .upload(name.into(), parent.map(Into::into), data.into())
            .map(Into::into)
            .map_err(Into::into)
    }
    fn update(&mut self, id: &str, data: &[u8]) -> Result<DriveFile, DriveError> {
        self.0
            .update(id.into(), data.into())
            .map(Into::into)
            .map_err(Into::into)
    }
    fn create_folder(&mut self, name: &str, parent: Option<&str>) -> Result<DriveFile, DriveError> {
        self.0
            .create_folder(name.into(), parent.map(Into::into))
            .map(Into::into)
            .map_err(Into::into)
    }
    fn delete(&mut self, id: &str) -> Result<(), DriveError> {
        self.0.delete(id.into()).map_err(Into::into)
    }
}
#[derive(uniffi::Enum)]
pub enum CoreSyncMode {
    Both,
    Push,
    Pull,
}
impl From<CoreSyncMode> for SyncMode {
    fn from(m: CoreSyncMode) -> Self {
        match m {
            CoreSyncMode::Both => Self::Both,
            CoreSyncMode::Push => Self::Push,
            CoreSyncMode::Pull => Self::Pull,
        }
    }
}
#[derive(uniffi::Record)]
pub struct CoreSyncReport {
    pub pushed: u64,
    pub pulled: u64,
    pub conflicts: u64,
    pub deletions: u64,
    pub unreadable: u64,
    pub locked_local: u64,
    pub removed_local_only: u64,
    pub conflict_copies: Vec<String>,
}
impl From<SyncReport> for CoreSyncReport {
    fn from(r: SyncReport) -> Self {
        Self {
            pushed: r.pushed as u64,
            pulled: r.pulled as u64,
            conflicts: r.conflicts as u64,
            deletions: r.deletions as u64,
            unreadable: r.unreadable as u64,
            locked_local: r.locked_local as u64,
            removed_local_only: r.removed_local_only as u64,
            conflict_copies: r
                .conflict_copies
                .into_iter()
                .map(|id| id.raw_value)
                .collect(),
        }
    }
}
#[uniffi::export(with_foreign)]
pub trait CoreSyncHooks: Send + Sync {
    fn generate_id(&self) -> String;
    fn after_scan(&self);
}
struct Ids(Arc<dyn CoreSyncHooks>);
impl mdemo_core::store::IdSource for Ids {
    fn next_id(&self, _: mdemo_core::meta::MemoDate) -> mdemo_core::id::MemoID {
        mdemo_core::id::MemoID::new(self.0.generate_id())
    }
}
#[derive(uniffi::Object)]
pub struct CoreSyncService {
    service: SyncService,
}
#[uniffi::export]
impl CoreSyncService {
    #[uniffi::constructor]
    pub fn new(
        local: String,
        remote: String,
        state: String,
        keys: Arc<dyn CoreKeyStore>,
        hooks: Arc<dyn CoreSyncHooks>,
    ) -> Arc<Self> {
        let mut service = SyncService::new(local, remote, state);
        service.keys = Arc::new(Keys(keys));
        service.ids = Arc::new(Ids(hooks.clone()));
        service.after_scan = Some(Box::new(move || hooks.after_scan()));
        Arc::new(Self { service })
    }
    pub fn sync(&self, mode: CoreSyncMode) -> Result<CoreSyncReport, CoreSyncError> {
        self.service
            .sync(mode.into())
            .map(Into::into)
            .map_err(error)
    }
    pub fn enforce_privacy(&self) -> Result<CoreSyncReport, CoreSyncError> {
        self.service
            .enforce_privacy()
            .map(Into::into)
            .map_err(error)
    }
}
#[uniffi::export]
pub fn core_drive_sync(
    service: Arc<CoreSyncService>,
    state: String,
    api: Arc<dyn CoreDriveApi>,
    mode: CoreSyncMode,
    privacy: bool,
) -> Result<CoreSyncReport, CoreSyncError> {
    // 호출별 엔진을 구성하되 키체인과 훅은 같은 콜백을 공유한다.
    let s = &service.service;
    let mut engine = SyncService::new(
        s.local_root.clone(),
        s.remote_root.clone(),
        s.state_url.clone(),
    );
    engine.keys = s.keys.clone();
    engine.clock = s.clock.clone();
    engine.ids = s.ids.clone();
    let service = service.clone();
    engine.after_scan = Some(Box::new(move || {
        if let Some(hook) = &service.service.after_scan {
            hook();
        }
    }));
    let mirror = mdemo_sync::DriveMirrorSync {
        service: engine,
        state_url: state.into(),
    };
    let mut api = Drive(api);
    (if privacy {
        mirror.enforce_privacy(&mut api)
    } else {
        mirror.sync(&mut api, mode.into())
    })
    .map(Into::into)
    .map_err(error)
}
#[uniffi::export]
pub fn core_export_backup(root: String, destination: String) -> Result<u64, CoreSyncError> {
    mdemo_sync::backup::BackupService::new(root)
        .export_backup(std::path::Path::new(&destination))
        .map(|n| n as u64)
        .map_err(error)
}
#[uniffi::export]
pub fn core_import_backup(
    root: String,
    archive: String,
    replace: bool,
    keys: Arc<dyn CoreKeyStore>,
) -> Result<u64, CoreSyncError> {
    let mut backup = mdemo_sync::backup::BackupService::new(root);
    backup.keys = Arc::new(Keys(keys));
    backup
        .import_backup(std::path::Path::new(&archive), replace)
        .map(|n| n as u64)
        .map_err(error)
}
