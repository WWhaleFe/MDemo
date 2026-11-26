use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceMemoState {
    pub frame: Vec<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "displayID")]
    pub display_id: Option<String>,
    pub is_collapsed: bool,
}
pub type DeviceStates = BTreeMap<String, DeviceMemoState>;
pub fn decode(bytes: &[u8]) -> DeviceStates {
    serde_json::from_slice(bytes).unwrap_or_default()
}
#[cfg(test)]
mod tests {
    #[test]
    fn bad_file_is_empty() {
        assert!(super::decode(b"{}").is_empty());
        assert!(super::decode(br#"{"x":{"frame":[]}}"#).is_empty());
    }
}
