use crate::id::MemoID;
use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LineStyle {
    Solid,
    Dashed,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Arrows {
    None,
    Forward,
    Both,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MemoLinkKind {
    Line,
    Flow,
    Both,
    Related,
    Dashto,
    Dashboth,
    Contain,
    Block,
    Oppose,
    Same,
}
impl MemoLinkKind {
    pub const ALL: [Self; 10] = [
        Self::Line,
        Self::Flow,
        Self::Both,
        Self::Related,
        Self::Dashto,
        Self::Dashboth,
        Self::Contain,
        Self::Block,
        Self::Oppose,
        Self::Same,
    ];
    pub fn token(self) -> &'static str {
        match self {
            Self::Line => "line",
            Self::Flow => "flow",
            Self::Both => "both",
            Self::Related => "related",
            Self::Dashto => "dashto",
            Self::Dashboth => "dashboth",
            Self::Contain => "contain",
            Self::Block => "block",
            Self::Oppose => "oppose",
            Self::Same => "same",
        }
    }
    pub fn from_style(style: LineStyle, arrows: Arrows) -> Self {
        match (style, arrows) {
            (LineStyle::Solid, Arrows::None) => Self::Line,
            (LineStyle::Solid, Arrows::Forward) => Self::Flow,
            (LineStyle::Solid, Arrows::Both) => Self::Both,
            (LineStyle::Dashed, Arrows::None) => Self::Related,
            (LineStyle::Dashed, Arrows::Forward) => Self::Dashto,
            (LineStyle::Dashed, Arrows::Both) => Self::Dashboth,
        }
    }
    pub fn line_style(self) -> LineStyle {
        if self.dashed() {
            LineStyle::Dashed
        } else {
            LineStyle::Solid
        }
    }
    pub fn group(self) -> usize {
        if Self::ALL[..3].contains(&self) {
            0
        } else if Self::ALL[..6].contains(&self) {
            1
        } else {
            2
        }
    }
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Line => "연결",
            Self::Flow => "흐름",
            Self::Both => "상호",
            Self::Related => "관련",
            Self::Dashto => "참고",
            Self::Dashboth => "서로 참고",
            Self::Contain => "포함",
            Self::Block => "막힘",
            Self::Oppose => "반대",
            Self::Same => "같음",
        }
    }
    pub fn dashed(self) -> bool {
        matches!(self, Self::Related | Self::Dashto | Self::Dashboth)
    }
    pub fn arrows(self) -> Arrows {
        match self {
            Self::Flow | Self::Dashto => Arrows::Forward,
            Self::Both | Self::Dashboth => Arrows::Both,
            _ => Arrows::None,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoLink {
    pub to: MemoID,
    pub kind: MemoLinkKind,
    #[serde(default, deserialize_with = "decode_label")]
    pub label: String,
    #[serde(default, deserialize_with = "decode_suffix")]
    pub unknown_suffix: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub preserves_raw_label: Option<bool>,
}
impl PartialEq for MemoLink {
    fn eq(&self, other: &Self) -> bool {
        self.to == other.to
            && self.kind == other.kind
            && crate::unicode::nfd(&self.label) == crate::unicode::nfd(&other.label)
            && crate::unicode::nfd(&self.unknown_suffix)
                == crate::unicode::nfd(&other.unknown_suffix)
            && self.preserves_raw_label == other.preserves_raw_label
    }
}
impl Eq for MemoLink {}
impl std::hash::Hash for MemoLink {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.to.hash(state);
        self.kind.hash(state);
        crate::unicode::nfd(&self.label).hash(state);
        crate::unicode::nfd(&self.unknown_suffix).hash(state);
        self.preserves_raw_label.hash(state);
    }
}
fn decode_label<'de, D: serde::Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(MemoLink::normalize_label(
        &Option::<String>::deserialize(d)?.unwrap_or_default(),
    ))
}
impl MemoLink {
    pub fn new(to: MemoID, kind: MemoLinkKind, label: &str) -> Self {
        Self {
            to,
            kind,
            label: Self::normalize_label(label),
            unknown_suffix: String::new(),
            preserves_raw_label: None,
        }
    }
    pub fn set_line_style(&mut self, style: LineStyle) {
        self.kind = MemoLinkKind::from_style(style, self.kind.arrows());
    }
    pub fn set_arrows(&mut self, arrows: Arrows) {
        self.kind = MemoLinkKind::from_style(self.kind.line_style(), arrows);
    }
    pub fn set_label(&mut self, label: &str) {
        self.label = Self::normalize_label(label);
    }

    pub fn normalize_label(value: &str) -> String {
        value.graphemes(true).take(20).collect()
    }
}
pub fn percent_encode(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}
pub fn percent_decode(s: &str) -> Option<String> {
    let mut out = Vec::new();
    let mut bytes = s.bytes();
    while let Some(b) = bytes.next() {
        if b == b'%' {
            let a = (bytes.next()? as char).to_digit(16)?;
            let c = (bytes.next()? as char).to_digit(16)?;
            out.push((a * 16 + c) as u8);
        } else {
            out.push(b);
        }
    }
    String::from_utf8(out).ok()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn graphemes_and_percent() {
        for s in ["👩‍👩‍👧‍👦", "e\u{301}", "한"] {
            assert_eq!(MemoLink::normalize_label(&s.repeat(21)), s.repeat(20));
        }
        assert_eq!(percent_encode("a-한"), "a%2D%ED%95%9C");
        assert_eq!(percent_decode("%FF"), None);
        assert_eq!(percent_decode("%zz"), None);
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MemoEdge {
    pub from: MemoID,
    pub to: MemoID,
    pub kind: MemoLinkKind,
    pub label: String,
}
impl MemoEdge {
    pub fn new(from: MemoID, to: MemoID, kind: MemoLinkKind, label: &str) -> Self {
        Self {
            from,
            to,
            kind,
            label: MemoLink::normalize_label(label),
        }
    }
    pub fn display_label(&self) -> String {
        if self.label.is_empty() {
            self.kind.display_name().into()
        } else {
            format!("{} · {}", self.kind.display_name(), self.label)
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MemoFlow {
    pub id: MemoID,
    pub memo_ids: Vec<MemoID>,
}
#[cfg(test)]
mod model_tests {
    use super::*;
    #[test]
    fn kind_styles_and_mutation() {
        for kind in MemoLinkKind::ALL {
            assert!(!kind.display_name().is_empty());
            assert!(kind.group() < 3);
        }
        let id = MemoID::new("01ARZ3NDEKTSV4RRFFQ69G5F00");
        let mut link = MemoLink::new(id.clone(), MemoLinkKind::Contain, "e\u{301}");
        link.set_line_style(LineStyle::Dashed);
        assert_eq!(link.kind, MemoLinkKind::Related);
        link.set_arrows(Arrows::Both);
        assert_eq!(link.kind, MemoLinkKind::Dashboth);
        let a = MemoLink::new(id.clone(), MemoLinkKind::Flow, "é");
        let b = MemoLink::new(id, MemoLinkKind::Flow, "e\u{301}");
        assert_eq!(a, b);
        assert_eq!(std::collections::HashSet::from([a, b]).len(), 1);
        link.set_label(&"👩‍💻".repeat(21));
        assert_eq!(link.label, "👩‍💻".repeat(20));
    }
    #[test]
    fn old_json_and_label_limit() {
        let old = r#"{"to":{"rawValue":"fake"},"kind":"flow"}"#;
        let link: MemoLink = serde_json::from_str(old).unwrap();
        assert!(link.label.is_empty());
        assert_eq!(link.preserves_raw_label, None);
        let raw = serde_json::json!({"to":{"rawValue":"fake"},"kind":"flow","label":"한".repeat(21),"unknownSuffix":"~next","preservesRawLabel":true});
        let link: MemoLink = serde_json::from_value(raw).unwrap();
        assert_eq!(link.label, "한".repeat(20));
        assert_eq!(link.preserves_raw_label, Some(true));
    }
}

fn decode_suffix<'de, D: serde::Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.unwrap_or_default())
}
