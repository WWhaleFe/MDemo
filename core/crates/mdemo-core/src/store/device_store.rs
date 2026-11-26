//! 기기별 창 상태 보관 (Swift `DeviceStateStore`, SYNC-07). 동기화 대상이 아니다.

use super::atomic_write;
use crate::{device_state::{self, DeviceMemoState, DeviceStates}, id::MemoID, json};
use std::{fs, path::PathBuf};

pub struct DeviceStateStore {
    path: PathBuf,
    states: DeviceStates,
}

impl DeviceStateStore {
    /// 파일이 없거나 깨져 있으면 빈 상태로 시작한다.
    pub fn new(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let states = fs::read(&path).map(|d| device_state::decode(&d)).unwrap_or_default();
        Self { path, states }
    }

    pub fn state(&self, id: &MemoID) -> Option<&DeviceMemoState> {
        self.states.get(&id.raw_value)
    }

    pub fn set_state(&mut self, state: DeviceMemoState, id: &MemoID) {
        self.states.insert(id.raw_value.clone(), state);
    }

    pub fn remove_state(&mut self, id: &MemoID) {
        self.states.remove(&id.raw_value);
    }

    /// 디스크에 기록한다. 창 위치는 잃어도 메모는 잃지 않으므로 실패는 조용히 넘긴다.
    pub fn flush(&self) {
        let _ = (|| -> Result<(), Box<dyn std::error::Error>> {
            if let Some(parent) = self.path.parent() {
                fs::create_dir_all(parent)?;
            }
            atomic_write(&self.path, &json::encode(&self.states, true, true)?)?;
            Ok(())
        })();
    }
}
