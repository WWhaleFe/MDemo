//! Swift 문자열 규칙의 Rust 재현. 마크다운 엔진은 전부 이 도우미를 거쳐 글자를 다룬다.
//!
//! - `Character`는 확장 문자소이고, 같음은 정규 동치다(`"\u{1FEF}" == "`"`, `"\u{0387}" == "·"`).
//! - `hasPrefix` · `hasSuffix` · `contains`는 문자소 경계에서만 일치한다(`"-\u{301}x"`는 `"-"`로 시작하지 않는다).
//! - `components(separatedBy: "\n")`은 스칼라마다 자르고, `replacingOccurrences`는 스칼라 단위로 찾되
//!   바로 뒤에 결합 기호(Extend)가 붙은 자리는 건너뛴다.
//! - `trimmingCharacters`는 스칼라 단위다. `Character.isNumber` · `isNewline`은 첫 스칼라만 본다.
//! - `lowercased()`는 글자마다 대응 표만 쓴다(마지막 시그마 문맥 없음).

use crate::numeric_table::{DECIMAL, NUMERIC};
use mdemo_core::{frontmatter::trim, nfd};
use unicode_segmentation::UnicodeSegmentation;

/// 문자열을 Swift `Array(string)`처럼 문자소 조각으로 나눈다.
pub fn chars(s: &str) -> Vec<&str> {
    s.graphemes(true).collect()
}

/// Swift `Character ==`. 같은 글자이거나 정규 분해가 같으면 같다.
pub fn ch_eq(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    // 정규 분해가 ASCII 한 글자가 되는 비ASCII 글자는 U+037E(;) · U+1FEF(`) · U+212A(K) 셋뿐이다.
    // 그 밖의 ASCII 한 글자와는 같을 수 없으니 분해를 건너뛴다(속도).
    let plain = |s: &str| s.len() == 1 && !matches!(s, ";" | "`" | "K");
    if plain(a) || plain(b) {
        return false;
    }
    !(a.is_ascii() && b.is_ascii()) && nfd(a) == nfd(b)
}

/// 두 문자소 열이 글자마다 같은가.
pub fn seq_eq(a: &[&str], b: &[&str]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| ch_eq(x, y))
}

/// Swift `String.hasPrefix`. 둘 다 ASCII면 바이트 비교(표준 라이브러리도 그렇다), 아니면 문자소 단위 비교.
pub fn has_prefix(s: &str, prefix: &str) -> bool {
    if s.is_ascii() && prefix.is_ascii() {
        return s.as_bytes().starts_with(prefix.as_bytes());
    }
    let (sc, pc) = (chars(s), chars(prefix));
    pc.len() <= sc.len() && seq_eq(&sc[..pc.len()], &pc)
}

/// Swift `String.hasSuffix`.
pub fn has_suffix(s: &str, suffix: &str) -> bool {
    if s.is_ascii() && suffix.is_ascii() {
        return s.as_bytes().ends_with(suffix.as_bytes());
    }
    let (sc, pc) = (chars(s), chars(suffix));
    pc.len() <= sc.len() && seq_eq(&sc[sc.len() - pc.len()..], &pc)
}

/// 문자소 열 안에 부분 열이 있는가(문자소 경계 기준 `contains`). 빈 부분 열은 항상 있다.
pub fn contains_seq(haystack: &[&str], needle: &[&str]) -> bool {
    if needle.is_empty() {
        return true;
    }
    needle.len() <= haystack.len() && (0..=haystack.len() - needle.len()).any(|i| seq_eq(&haystack[i..i + needle.len()], needle))
}

/// Swift `String.contains(String)`.
pub fn contains(haystack: &str, needle: &str) -> bool {
    contains_seq(&chars(haystack), &chars(needle))
}

/// Swift `String.contains(Character)`.
pub fn contains_char(haystack: &str, character: &str) -> bool {
    haystack.graphemes(true).any(|g| ch_eq(g, character))
}

/// Swift `String ==`(정규 동치).
pub fn str_eq(a: &str, b: &str) -> bool {
    a == b || (!(a.is_ascii() && b.is_ascii()) && nfd(a) == nfd(b))
}

/// 앞에서 `count`개 문자소를 뗀 나머지(Swift `dropFirst`).
pub fn drop_first(s: &str, count: usize) -> &str {
    match s.grapheme_indices(true).nth(count) {
        Some((i, _)) => &s[i..],
        None => "",
    }
}

/// 문자소 개수(Swift `count`).
pub fn count(s: &str) -> usize {
    s.graphemes(true).count()
}

/// Foundation `trimmingCharacters(in: .whitespaces)`.
pub fn trim_ws(s: &str) -> &str {
    trim(s)
}

/// `trimmingCharacters(in: CharacterSet(charactersIn: ...))`. 스칼라 단위다.
pub fn trim_set<'a>(s: &'a str, set: &[char]) -> &'a str {
    s.trim_matches(|c| set.contains(&c))
}

/// Foundation `components(separatedBy: "\n")`. 줄바꿈 문자는 앞뒤 글자와 상관없이 스칼라 하나마다 자른다
/// (`"\r\n"` 한가운데의 `"\n"`에서도 자르고 `"\r"`은 앞 줄에 남는다. Swift 관찰).
pub fn split_lines(s: &str) -> Vec<&str> {
    s.split('\n').collect()
}

/// 문자소가 `delimiter`와 같은 자리에서 자른다(Swift `split(separator:omittingEmptySubsequences: false)`).
pub fn split_char<'a>(s: &'a str, delimiter: &str) -> Vec<&'a str> {
    let mut result = Vec::new();
    let mut start = 0;
    for (i, g) in s.grapheme_indices(true) {
        if ch_eq(g, delimiter) {
            result.push(&s[start..i]);
            start = i + g.len();
        }
    }
    result.push(&s[start..]);
    result
}

/// Foundation `replacingOccurrences(of:with:)`. 스칼라 단위로 찾되, 일치 바로 뒤에 결합 기호(Grapheme_Cluster_Break=Extend:
/// 결합 악센트 · 변이 선택자 · 이모지 피부색 등)가 붙어 있으면 그 자리는 바꾸지 않는다(Swift 관찰).
/// ZWJ · 간격 결합 기호 · 한글 자모가 뒤따르는 자리는 바꾼다. 일치 앞쪽 글자는 상관없다.
pub fn replace_char(s: &str, from: &str, to: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(pos) = rest.find(from) {
        let end = pos + from.len();
        let blocked = rest[end..].chars().next().is_some_and(is_grapheme_extend);
        out.push_str(&rest[..pos]);
        if blocked {
            // 이 자리는 그대로 두고 다음 스칼라부터 다시 찾는다.
            let step = rest[pos..].chars().next().map_or(1, char::len_utf8);
            out.push_str(&rest[pos..pos + step]);
            rest = &rest[pos + step..];
        } else {
            out.push_str(to);
            rest = &rest[end..];
        }
    }
    out.push_str(rest);
    out
}

/// 문자소 경계 속성이 Extend인가(ZWJ · 간격 결합 기호는 아니다).
/// "그림 + 이 글자 + ZWJ + 그림"이 한 문자소로 묶이는 것은 이 글자가 Extend일 때뿐이라는 점을 이용한다.
fn is_grapheme_extend(c: char) -> bool {
    let probe = format!("\u{1F600}{c}\u{200D}\u{1F600}");
    probe.graphemes(true).count() == 1
}

/// `Character.isNumber`: 첫 스칼라의 Numeric_Type이 None이 아니다.
pub fn is_number(g: &str) -> bool {
    g.chars().next().is_some_and(|c| in_table(NUMERIC, c))
}

/// ICU `\d`(Numeric_Type=Decimal)에 해당하는 스칼라인가.
pub fn is_decimal(c: char) -> bool {
    in_table(DECIMAL, c)
}

fn in_table(table: &[(u32, u32)], c: char) -> bool {
    let cp = c as u32;
    table
        .binary_search_by(|&(s, e)| {
            if cp < s {
                std::cmp::Ordering::Greater
            } else if cp > e {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Equal
            }
        })
        .is_ok()
}

/// `Character.isNewline`: 첫 스칼라가 줄바꿈류다.
pub fn is_newline(g: &str) -> bool {
    matches!(g.chars().next(), Some('\u{A}'..='\u{D}' | '\u{85}' | '\u{2028}' | '\u{2029}'))
}

/// `Character.isHexDigit`: 스칼라 하나짜리 ASCII 또는 전각 16진 숫자.
pub fn is_hex_digit(g: &str) -> bool {
    let mut it = g.chars();
    match (it.next(), it.next()) {
        (Some(c), None) => c.is_ascii_hexdigit() || matches!(c, '\u{FF10}'..='\u{FF19}' | '\u{FF21}'..='\u{FF26}' | '\u{FF41}'..='\u{FF46}'),
        _ => false,
    }
}

/// ICU `\s`: White_Space 속성.
pub fn is_regex_space(c: char) -> bool {
    c.is_whitespace()
}

/// Swift `lowercased()`: 글자마다 소문자 대응(문맥 규칙 없음).
pub fn lowercased(s: &str) -> String {
    s.chars().flat_map(char::to_lowercase).collect()
}

/// Swift `uppercased()`: 글자마다 대문자 대응.
pub fn uppercased(s: &str) -> String {
    s.chars().flat_map(char::to_uppercase).collect()
}

/// Swift `Int(String)`에 해당하는, 부호 없는 ASCII 숫자 열 읽기. 비었거나 범위를 넘으면 None.
pub fn parse_int(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}
