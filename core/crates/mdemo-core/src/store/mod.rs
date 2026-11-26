//! 저장소(Swift `Storage/` 와 `MemoStore` 중 파일에 닿는 부분의 Rust 판).
//!
//! 폴더 구조와 파일 이름, 쓰기 순서, 조용히 넘기는 오류까지 Swift 구현을 그대로 따른다.
//! 시각과 ID는 `Clock` / `IdSource`로 주입해 시험과 시나리오가 고정값을 쓴다.
//! 잠긴 메모의 흐름(암호, 열쇠, 안전 삭제)은 P4에서 옮겼다(`lock_flow`, `secure_delete`, `mdemo-crypto`).

use crate::{id::MemoID, meta::MemoDate};
use std::{
    fmt, fs, io,
    io::Write,
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
    sync::Mutex,
    time::{Duration, SystemTime},
};

pub mod attachments;
pub mod b64;
pub mod device_store;
mod digits;
mod lock_flow;
pub mod memo_store;
pub mod repository;
pub mod search;
pub mod secure_delete;
pub mod summary;

#[cfg(test)]
mod lock_tests;
#[cfg(test)]
mod tests;

pub use device_store::DeviceStateStore;
pub use memo_store::MemoStore;
pub use repository::FileMemoRepository;
pub use summary::MemoSummary;

/// Swift `MemoLockError`와 저장소 오류를 합친 것.
#[derive(Debug)]
pub enum StoreError {
    Io(io::Error),
    /// 앞머리 읽기 실패 등 파일 형식 문제.
    Format(String),
    /// 파기 장부에 있는 메모 (Swift `MemoLockError.destroyed`).
    Destroyed,
    /// 파일의 ID가 폴더 ID와 다르다 (Swift `MemoLockError.damaged`).
    Damaged,
    /// 잠긴 메모를 형식에 맞지 않게 저장하려 했다 (Swift `MemoLockError.locked`).
    Locked,
    /// 암호 형식이 맞지 않는 새 암호 (Swift `MemoLockError.invalidPassword`).
    InvalidPassword,
    /// 열쇠 저장소에 열쇠가 없다 (Swift `MemoLockError.missingKey`).
    MissingKey,
    /// 암호가 맞지 않는다 (Swift `MemoLockError.wrongPassword`).
    WrongPassword,
    /// 열쇠 저장소나 난수 생성 실패 (Swift `MemoLockError.keychain`).
    KeyStore(String),
    /// AES-GCM 태그 불일치. Swift에서는 `MemoLockError`가 아닌 `CryptoKitError.authenticationFailure`로 올라온다.
    Authentication,
    /// 암호문이 너무 짧다 (Swift `CryptoKitError.incorrectParameterSize`).
    IncorrectSize,
    /// 첨부 이름이 폴더 밖을 가리키는 등 쓸 수 없다.
    BadName(String),
    Other(String),
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(e) => write!(f, "입출력 오류: {e}"),
            Self::Format(s) => write!(f, "형식 오류: {s}"),
            Self::Destroyed => f.write_str("파기된 메모"),
            Self::Damaged => f.write_str("손상된 메모"),
            Self::Locked => f.write_str("잠긴 메모"),
            Self::InvalidPassword => f.write_str("4~6자, 영문 대소문자와 숫자"),
            Self::MissingKey => f.write_str("열쇠가 없어 열 수 없는 잠긴 메모"),
            Self::WrongPassword => f.write_str("암호가 맞지 않습니다"),
            Self::KeyStore(s) => write!(f, "열쇠 저장소 오류: {s}"),
            Self::Authentication => f.write_str("인증 실패"),
            Self::IncorrectSize => f.write_str("암호문 길이 오류"),
            Self::BadName(s) => write!(f, "쓸 수 없는 이름: {s}"),
            Self::Other(s) => f.write_str(s),
        }
    }
}
impl std::error::Error for StoreError {}
impl From<io::Error> for StoreError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<mdemo_crypto::LockError> for StoreError {
    fn from(e: mdemo_crypto::LockError) -> Self {
        use mdemo_crypto::LockError as L;
        match e {
            L::InvalidPassword => Self::InvalidPassword,
            L::MissingKey => Self::MissingKey,
            L::WrongPassword => Self::WrongPassword,
            L::Damaged => Self::Damaged,
            L::Locked => Self::Locked,
            L::Destroyed => Self::Destroyed,
            L::KeyStore(s) => Self::KeyStore(s),
            L::Authentication => Self::Authentication,
            L::IncorrectSize => Self::IncorrectSize,
        }
    }
}
impl From<Box<dyn std::error::Error>> for StoreError {
    fn from(e: Box<dyn std::error::Error>) -> Self {
        Self::Other(e.to_string())
    }
}
impl From<serde_json::Error> for StoreError {
    fn from(e: serde_json::Error) -> Self {
        Self::Other(e.to_string())
    }
}

pub type StoreResult<T> = Result<T, StoreError>;

/// 현재 시각 공급원. 시험과 시나리오는 고정값을 쓴다.
pub trait Clock: Send + Sync {
    fn now(&self) -> MemoDate;
}

/// 새 ID 공급원. `now`는 ID 앞부분(시각)에 쓸 현재 시각이다.
pub trait IdSource: Send + Sync {
    fn next_id(&self, now: MemoDate) -> MemoID;
}

/// 실제 시계. Swift `Date()`처럼 반올림하지 않는다.
pub struct SystemClock;
impl Clock for SystemClock {
    fn now(&self) -> MemoDate {
        MemoDate::now()
    }
}

/// Swift `MemoMeta.now()`처럼 밀리초로 맞춘 실제 시계.
pub struct SystemMillisClock;
impl Clock for SystemMillisClock {
    fn now(&self) -> MemoDate {
        MemoDate::now_milliseconds()
    }
}

/// 실제 ID 생성기.
pub struct SystemIds;
impl IdSource for SystemIds {
    fn next_id(&self, now: MemoDate) -> MemoID {
        let ms = ((now.0 + UNIX_TO_REFERENCE) * 1000.).floor() as i64;
        MemoID::generate_at(ms).expect("난수 생성 실패")
    }
}

/// 값을 바꿔 가며 쓰는 고정 시계(시험 · 시나리오용).
pub struct ManualClock(Mutex<f64>);
impl ManualClock {
    pub fn new(at: MemoDate) -> Self {
        Self(Mutex::new(at.0))
    }
    pub fn set(&self, at: MemoDate) {
        *self.0.lock().unwrap() = at.0;
    }
}
impl Clock for ManualClock {
    fn now(&self) -> MemoDate {
        MemoDate(*self.0.lock().unwrap())
    }
}

/// 미리 넣어 둔 ID를 차례로 돌려준다(시험 · 시나리오용). 바닥나면 패닉한다.
#[derive(Default)]
pub struct QueuedIds(Mutex<std::collections::VecDeque<MemoID>>);
impl QueuedIds {
    pub fn push(&self, id: MemoID) {
        self.0.lock().unwrap().push_back(id);
    }
}
impl IdSource for QueuedIds {
    fn next_id(&self, _now: MemoDate) -> MemoID {
        self.0.lock().unwrap().pop_front().expect("준비된 ID가 없음")
    }
}

/// 2001-01-01 기준 초와 1970 기준 초의 차이.
pub const UNIX_TO_REFERENCE: f64 = 978_307_200.;

pub(crate) fn to_system_time(date: MemoDate) -> SystemTime {
    let unix = date.0 + UNIX_TO_REFERENCE;
    if unix >= 0. {
        SystemTime::UNIX_EPOCH + Duration::from_secs_f64(unix)
    } else {
        SystemTime::UNIX_EPOCH - Duration::from_secs_f64(-unix)
    }
}

pub(crate) fn from_system_time(time: SystemTime) -> MemoDate {
    let unix = match time.duration_since(SystemTime::UNIX_EPOCH) {
        Ok(d) => d.as_secs_f64(),
        Err(e) => -e.duration().as_secs_f64(),
    };
    MemoDate(unix - UNIX_TO_REFERENCE)
}

/// 파일 또는 폴더의 수정 시각.
pub fn modified_time(path: &Path) -> io::Result<MemoDate> {
    Ok(from_system_time(fs::metadata(path)?.modified()?))
}

/// 파일 또는 폴더의 수정 시각을 지정한다. 맥에서는 폴더도 읽기 전용으로 열어 바꾼다.
#[cfg(not(windows))]
pub fn set_modified_time(path: &Path, date: MemoDate) -> io::Result<()> {
    fs::File::open(path)?.set_modified(to_system_time(date))
}

/// Windows는 폴더를 열 때 백업 의미 플래그와 쓰기 권한이 필요하다.
#[cfg(windows)]
pub fn set_modified_time(path: &Path, date: MemoDate) -> io::Result<()> {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    fs::OpenOptions::new()
        .write(true)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)?
        .set_modified(to_system_time(date))
}

static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// 같은 폴더의 임시 파일에 쓴 뒤 이름을 바꾼다. 도중에 끊겨도 기존 파일은 그대로다 (DAT-08).
pub fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let temp = path.with_file_name(format!(
        ".{name}.tmp-{}-{}",
        std::process::id(),
        TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        let mut file = fs::File::create(&temp)?;
        file.write_all(bytes)?;
        // 이름을 바꾸기 전에 내용을 디스크에 반영한다. 암호 바꾸기에서 새 열쇠는 저장됐는데 앞머리(솔트 · 반복 횟수)가
        // 옛 값으로 남아 메모를 열 수 없게 되는 경우를 막는다(Gemini 교차 검수 지적).
        file.sync_all()?;
        drop(file);
        fs::rename(&temp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

/// 숨김 파일(이름이 `.`로 시작)을 뺀 하위 항목의 이름과 경로. Foundation의 `.skipsHiddenFiles`와 같다.
pub(crate) fn visible_entries(dir: &Path) -> io::Result<Vec<(String, std::path::PathBuf)>> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with('.') {
            entries.push((name, entry.path()));
        }
    }
    // 읽는 순서는 운영체제 마음이라 이름순으로 고정한다.
    entries.sort();
    Ok(entries)
}
