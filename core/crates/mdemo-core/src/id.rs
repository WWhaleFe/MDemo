use serde::{Deserialize, Serialize};
/// Swift와 같은 객체 형태로 저장하는 메모 식별자.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MemoID {
    #[serde(rename = "rawValue")]
    pub raw_value: String,
}
impl MemoID {
    pub fn new(value: impl Into<String>) -> Self {
        Self {
            raw_value: value.into(),
        }
    }
    /// 10자리 시각과 16자리 난수. 음수 시각은 Swift처럼 0으로 맞춘다.
    pub fn generate() -> Result<Self, getrandom::Error> {
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        Self::generate_at(millis)
    }
    pub fn generate_at(milliseconds: i64) -> Result<Self, getrandom::Error> {
        let alphabet = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
        let mut chars = [b'0'; 26];
        let mut time = milliseconds.max(0) as u64;
        for i in (0..10).rev() {
            chars[i] = alphabet[(time % 32) as usize];
            time /= 32;
        }
        let mut random = [0u8; 16];
        getrandom::getrandom(&mut random)?;
        for i in 0..16 {
            chars[i + 10] = alphabet[(random[i] % 32) as usize];
        }
        Ok(Self::new(String::from_utf8(chars.to_vec()).unwrap()))
    }
    pub fn is_valid(&self) -> bool {
        self.raw_value.len() == 26
            && self
                .raw_value
                .bytes()
                .all(|b| b"0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(&b))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn uppercase_only() {
        assert!(MemoID::new("01ARZ3NDEKTSV4RRFFQ69G5F00").is_valid());
        assert!(!MemoID::new("01arz3ndektsv4rrffq69g5f00").is_valid());
    }
}
#[cfg(test)]
mod generation_tests {
    #[test]
    fn time_order_and_negative_epoch() {
        let zero = super::MemoID::generate_at(-1).unwrap();
        let later = super::MemoID::generate_at(1).unwrap();
        assert!(zero.is_valid() && later.is_valid());
        assert_eq!(&zero.raw_value[..10], "0000000000");
        assert!(zero.raw_value < later.raw_value);
    }
}

impl std::fmt::Display for MemoID {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.raw_value)
    }
}
