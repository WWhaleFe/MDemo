//! 동기화와 백업. HTTP, OAuth와 토큰은 플랫폼 어댑터가 맡는다.
pub mod backup;
pub mod drive;
pub mod engine;
pub mod fake;
mod files;
mod md5;
pub mod state;
pub use drive::{DriveApi, DriveError, DriveFile, DriveMirrorSync};
pub use engine::{SyncMode, SyncReport, SyncService};
pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
#[cfg(test)]
mod tests;
