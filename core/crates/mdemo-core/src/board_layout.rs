use crate::id::MemoID;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Placement {
    pub x: f64,
    pub y: f64,
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BentoSpan {
    Small,
    Wide,
    Tall,
    Large,
}
impl BentoSpan {
    pub fn columns(self) -> usize {
        if matches!(self, Self::Wide | Self::Large) {
            2
        } else {
            1
        }
    }
    pub fn rows(self) -> usize {
        if matches!(self, Self::Tall | Self::Large) {
            2
        } else {
            1
        }
    }
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardLayout {
    #[serde(default, deserialize_with = "null_default")]
    pub placements: BTreeMap<String, Placement>,
    #[serde(default, deserialize_with = "null_default")]
    pub bento_spans: BTreeMap<String, BentoSpan>,
    #[serde(default, deserialize_with = "null_default")]
    pub manual_order: Vec<MemoID>,
}
impl BoardLayout {
    pub fn normalized_order(&self, ids: &[MemoID]) -> Vec<MemoID> {
        let alive: HashSet<_> = ids.iter().collect();
        let mut seen = HashSet::new();
        let saved: Vec<_> = self
            .manual_order
            .iter()
            .filter(|id| alive.contains(id) && seen.insert(*id))
            .cloned()
            .collect();
        ids.iter()
            .filter(|id| !seen.contains(id))
            .cloned()
            .chain(saved)
            .collect()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn defaults_and_order() {
        let mut b: BoardLayout = serde_json::from_str("{}").unwrap();
        let a = MemoID::new("a");
        let c = MemoID::new("c");
        b.manual_order = vec![a.clone(), a.clone(), MemoID::new("gone")];
        assert_eq!(b.normalized_order(&[c.clone(), a.clone()]), vec![c, a]);
        assert_eq!(BentoSpan::Large.rows(), 2);
    }
}

fn null_default<'de, D: serde::Deserializer<'de>, T: serde::Deserialize<'de> + Default>(
    d: D,
) -> Result<T, D::Error> {
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}
#[cfg(test)]
mod null_tests {
    #[test]
    fn legacy_null_fields() {
        let b: super::BoardLayout =
            serde_json::from_str(r#"{"placements":null,"bentoSpans":null,"manualOrder":null}"#)
                .unwrap();
        assert_eq!(b, super::BoardLayout::default());
    }
}
