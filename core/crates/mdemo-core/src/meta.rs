use crate::{id::MemoID, link::MemoLink};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
/// Swift Date와 같은 2001년 기준 초. JSON에서도 이 Double을 사용한다.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct MemoDate(pub f64);
impl MemoDate {
    pub fn parse(text: &str) -> Option<Self> {
        let d = DateTime::parse_from_rfc3339(text).ok()?;
        Some(Self(
            (d.timestamp() - 978_307_200) as f64 + d.timestamp_subsec_nanos() as f64 / 1e9,
        ))
    }
    pub fn now() -> Self {
        let d = Utc::now();
        Self(d.timestamp() as f64 + d.timestamp_subsec_nanos() as f64 / 1e9 - 978_307_200.)
    }
    pub fn now_milliseconds() -> Self {
        let now = Self::now().0 + 978_307_200.;
        Self((now * 1000.).round() / 1000. - 978_307_200.)
    }
    pub fn iso8601(self) -> String {
        let seconds = self.0.floor();
        let millis = ((self.0 - seconds) * 1000.).floor() as u32;
        DateTime::from_timestamp(seconds as i64 + 978_307_200, millis * 1_000_000)
            .expect("날짜 범위")
            .to_rfc3339_opts(SecondsFormat::Millis, true)
    }
}
/// 메모 메타데이터. 시각은 파일에 쓸 때만 UTC 밀리초 문자열로 바꾼다.
#[derive(Clone, Debug, PartialEq)]
pub struct MemoMeta {
    pub schema_version: i64,
    pub id: MemoID,
    pub title: Option<String>,
    pub group: Option<String>,
    pub color_hex: String,
    pub background_alpha: f64,
    pub text_alpha: f64,
    pub is_open: bool,
    pub is_pinned: bool,
    pub created: MemoDate,
    pub modified: MemoDate,
    pub conflict_of: Option<MemoID>,
    pub links: Vec<MemoLink>,
    pub is_locked: bool,
    pub lock_salt: Option<String>,
    pub lock_iterations: Option<i64>,
    pub lock_version: Option<i64>,
    pub lock_failures: Option<i64>,
}
impl MemoMeta {
    pub const CURRENT_SCHEMA_VERSION: i64 = 3;
    pub fn new(id: MemoID) -> Self {
        let now = MemoDate::now_milliseconds();
        Self {
            schema_version: 3,
            id,
            title: None,
            group: None,
            color_hex: MemoColor::PRESETS[0].1.into(),
            background_alpha: 0.95,
            text_alpha: 1.,
            is_open: true,
            is_pinned: true,
            created: now,
            modified: now,
            conflict_of: None,
            links: Vec::new(),
            is_locked: false,
            lock_salt: None,
            lock_iterations: None,
            lock_version: None,
            lock_failures: None,
        }
    }
    pub fn set_background_alpha(&mut self, value: f64) {
        self.background_alpha = clamp_alpha(value, 0.15);
    }
    pub fn set_text_alpha(&mut self, value: f64) {
        self.text_alpha = clamp_alpha(value, 0.3);
    }
}
pub fn clamp_alpha(value: f64, lower: f64) -> f64 {
    if value.is_nan() {
        value
    } else {
        value.clamp(lower, 1.0)
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct MemoColor {
    pub name: String,
    pub hex: String,
}
impl MemoColor {
    pub fn new(name: impl Into<String>, hex: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            hex: hex.into(),
        }
    }
    pub fn presets() -> Vec<Self> {
        Self::PRESETS
            .into_iter()
            .map(|(name, hex)| Self::new(name, hex))
            .collect()
    }

    pub const PRESETS: [(&'static str, &'static str); 8] = [
        ("노랑", "#FFF3B0"),
        ("복숭아", "#FFD9C0"),
        ("분홍", "#FFD1DC"),
        ("연보라", "#E4D4F4"),
        ("하늘", "#CDE7F6"),
        ("민트", "#CDEFE3"),
        ("연두", "#E2F0C4"),
        ("회색", "#E6E6E6"),
    ];
    pub fn components(s: &str) -> Option<(f64, f64, f64)> {
        let s = s.strip_prefix('#').unwrap_or(s);
        if s.len() != 6 {
            return None;
        }
        let n = u32::from_str_radix(s, 16).ok()?;
        Some((
            ((n >> 16) & 255) as f64 / 255.,
            ((n >> 8) & 255) as f64 / 255.,
            (n & 255) as f64 / 255.,
        ))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn alpha_and_color() {
        assert!(clamp_alpha(f64::NAN, 0.15).is_nan());
        assert_eq!(clamp_alpha(-1., 0.3), 0.3);
        assert_eq!(MemoColor::components("#FFFFFF"), Some((1., 1., 1.)));
        assert_eq!(MemoColor::components("oops"), None);
    }
}
#[cfg(test)]
mod date_tests {
    use super::*;
    #[test]
    fn swift_double_boundary() {
        for (raw, expected) in [
            ("1969-12-31T23:59:59.999Z", "1969-12-31T23:59:59.998Z"),
            ("1999-12-31T23:59:59.001-03:30", "2000-01-01T03:29:59.000Z"),
            ("2001-01-01T00:00:00.000499Z", "2001-01-01T00:00:00.000Z"),
            ("2001-01-01T00:00:00.999999Z", "2001-01-01T00:00:00.999Z"),
        ] {
            assert_eq!(MemoDate::parse(raw).unwrap().iso8601(), expected);
        }
        assert_eq!(
            crate::json::encode(&MemoDate(123.25), false, true).unwrap(),
            b"123.25"
        );
    }
    #[test]
    fn initial_meta_defaults() {
        let mut meta = MemoMeta::new(MemoID::new("01ARZ3NDEKTSV4RRFFQ69G5F00"));
        assert!(meta.is_open && meta.is_pinned && !meta.is_locked);
        assert_eq!(meta.created, meta.modified);
        meta.set_background_alpha(-1.);
        meta.set_text_alpha(2.);
        assert_eq!(meta.background_alpha, 0.15);
        assert_eq!(meta.text_alpha, 1.);
    }
}
