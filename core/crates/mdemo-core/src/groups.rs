pub fn decode(bytes: &[u8]) -> Vec<String> {
    serde_json::from_slice(bytes).unwrap_or_default()
}
pub fn encode(groups: &[String]) -> Result<Vec<u8>, serde_json::Error> {
    crate::json::encode(groups, true, false)
}
#[cfg(test)]
mod tests {
    #[test]
    fn preserves_order() {
        let g = super::decode(br#"["b","a","b"]"#);
        assert_eq!(g, vec!["b", "a", "b"]);
        assert!(super::decode(b"{}").is_empty());
    }
}
