//! 표준 Base64(패딩 있음). 외부 크레이트 없이 시나리오 입력과 잠금 본문 검사에만 쓴다.

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn encode(bytes: &[u8]) -> String {
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16
            | (*chunk.get(1).unwrap_or(&0) as u32) << 8
            | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Foundation `Data(base64Encoded:)`와 같이 공백 · 줄바꿈이 섞이거나 패딩이 틀리면 실패한다.
pub fn decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if bytes.len() % 4 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for (index, quad) in bytes.chunks(4).enumerate() {
        let last = (index + 1) * 4 == bytes.len();
        let padding = quad.iter().rev().take_while(|b| **b == b'=').count();
        if padding > 2 || (padding > 0 && !last) {
            return None;
        }
        let mut n = 0u32;
        for (i, b) in quad.iter().enumerate() {
            let value = if i >= 4 - padding {
                0
            } else {
                ALPHABET.iter().position(|a| a == b)? as u32
            };
            n = n << 6 | value;
        }
        out.push((n >> 16) as u8);
        if padding < 2 {
            out.push((n >> 8) as u8);
        }
        if padding < 1 {
            out.push(n as u8);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn round_trip() {
        for data in [&b""[..], b"a", b"ab", b"abc", b"abcd", &[0, 255, 128, 7, 9]] {
            assert_eq!(decode(&encode(data)).unwrap(), data);
        }
        assert_eq!(encode(b"ab"), "YWI=");
        assert!(decode("YW I=").is_none());
        assert!(decode("YWI").is_none());
        assert!(decode("=AAA").is_none());
    }
}
