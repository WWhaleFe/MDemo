//! 메모 찾기 (Swift `MemoSearch.matches`, `FileMemoRepository.searchBodies`, SRC-01).
//!
//! Swift의 `localizedCaseInsensitiveContains`를 골든 `search-cases.json`(Swift 실제 판정과 바이트 비교)으로
//! 맞춘 근사다. 확인된 규칙:
//! - 정규 분해(NFD)가 같으면 같다. 한글 완성형은 초성 · 중성 · 종성으로 풀어 비교하고, 풀린 자모 한가운데서는 시작하거나 끝날 수 없다("하"는 "한"에 걸리지 않는다).
//! - 대소문자는 전체 대소문자 접기에 가깝다(ß = SS, ﬁ = FI, ſ = S, ς = σ). 터키어 ı, İ는 접지 않는다.
//!   그리스어 확장(U+1F00대)은 접지 않는다(ᾳ는 "αι"와 다르다).
//! - 일치는 원래 글자 한가운데서 시작하거나 끝날 수 없다(ß의 "s", ﬃ의 "f", é의 분해된 결합 기호 등).
//!   글자 뒤에 결합 기호 · 이모지 피부색 · 변이 선택자 · 반각 탁점이 이어지면 그 앞에서 끝날 수 없고,
//!   ZWJ 바로 뒤에서도 끝날 수 없다(뒤에 문자가 오거나, 이모지 뒤의 ZWJ에 이모지가 이어질 때만. 맨 앞의 ZWJ는 예외). 결합 기호만의 검색어는 분해되지 않은 곳에서 걸린다.
//! - 호환 분해가 숫자뿐이거나 Numeric_Type이 Decimal · Digit인 글자(전각, 아랍 인도, 위첨자, ①, ⑩ = "10" 등)는
//!   글자 바로 앞이 문자(알파벳)가 아닐 때만 ASCII 숫자와 같다. 검색어에서 십진 숫자(Numeric_Type=Decimal, 전각과 아랍 인도 포함)가 문자보다 먼저 나오면 결합 기호 · 변이 선택자 · ZWJ는 양쪽에서 무시된다("3e"가 "3e\u{301}"에 걸리고 "1\u{FE0F}\u{20E3}"이 "1"에 걸린다).
//!   전각 영문, 반각 가타카나, 로마 숫자, 분수, 호환 기호(™, ℓ)는 같게 보지 않는다.
//!
//! 이 규칙은 시스템 로케일이 달라도 같은지 확인하지 못했다(골든은 실행 환경의 로케일로 만든다).

use super::{digits::{DECIMAL, DIGITS}, repository::FileMemoRepository, summary::MemoSummary};
use crate::{frontmatter::{self, trim}, id::MemoID, unicode::nfd_chars};
use std::{collections::HashSet, fs};

/// 뒤에 오면 앞 글자와 한 덩어리로 보아 일치가 그 앞에서 끝날 수 없는 글자.
fn blocks_end_before(c: char) -> bool {
    matches!(c as u32,
        0x0300..=0x036F | 0x0483..=0x0489 | 0x0591..=0x05BD | 0x0610..=0x061A | 0x064B..=0x065F
        | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF
        | 0x3099..=0x309A | 0xFE00..=0xFE0F | 0xFE20..=0xFE2F
        | 0xFF9E..=0xFF9F | 0x1F3FB..=0x1F3FF)
}

/// 검색어에서 문자(알파벳)보다 십진 숫자가 먼저 나오는가. 문자 앞의 기호나 ①, ⑩ 같은 글자는 건너뛴다.
fn starts_numeric(needle: &str) -> bool {
    // 결합 기호로 시작하는 검색어도 숫자 규칙이 적용되지 않는 것으로 관찰된다.
    if needle.chars().next().is_some_and(|c| blocks_end_before(c) || c == '\u{200D}') {
        return false;
    }
    for c in needle.chars() {
        if DECIMAL.iter().any(|(s, e)| (*s..=*e).contains(&(c as u32))) {
            return true;
        }
        // 이모지나 깃발이 앞서면 숫자 규칙이 적용되지 않는 것으로 관찰된다.
        if is_letter(c) || is_emoji_like(c) {
            return false;
        }
    }
    false
}

/// 검색어에서는 BMP의 십진 숫자(전각, 아랍 인도 등)만 ASCII 숫자와 같다. ①, ¹, ⑩, 수학용 숫자는 본문 쪽에서만 접힌다.
fn folds_in_pattern(c: char) -> bool {
    (c as u32) < 0x10000 && DECIMAL.iter().any(|(s, e)| (*s..=*e).contains(&(c as u32)))
}

/// 문자(알파벳)인가. ℓ 같은 글자꼴 기호(U+2100대)는 문자로 보지 않는 것으로 관찰된다.
fn is_letter(c: char) -> bool {
    c.is_alphabetic() && !(0x2100..=0x214F).contains(&(c as u32))
}

fn is_emoji_like(c: char) -> bool {
    matches!(c as u32, 0x1F000..=0x1FAFF | 0x2600..=0x27BF | 0x2B00..=0x2BFF)
}

fn digits_of(c: char) -> Option<String> {
    let cp = c as u32;
    DIGITS.iter().find(|(start, end, _)| (*start..=*end).contains(&cp)).map(|(start, _, first)| {
        if start == &cp || first.len() > 1 {
            first.to_string()
        } else {
            char::from(first.as_bytes()[0] + (cp - start) as u8).to_string()
        }
    })
}

fn fold_char(c: char, out: &mut Vec<char>) {
    if c == '\u{1E9E}' {
        out.extend(['s', 's']);
    } else if matches!(c, 'ı' | 'İ') || (0x1F00..=0x1FFF).contains(&(c as u32)) {
        out.extend(c.to_lowercase());
    } else {
        // 대문자로 올렸다가 내려 ß, ﬁ, ſ, ς 같은 글자를 접는다.
        out.extend(c.to_uppercase().flat_map(char::to_lowercase));
    }
}

/// 접고 분해한 글자(원래 글자 번호 포함)와 원래 글자별 정보.
struct Prepared {
    chars: Vec<(char, usize)>,
    /// 원래 글자가 결합 기호인가. 접힌 뒤에는 글자가 되는 결합 기호(U+0345 → ι)도 앞 글자에 붙는 것으로 본다.
    marks: Vec<bool>,
    /// 숫자가 접혔는데 바로 앞이 문자인 원래 글자. 본문 쪽에서만 쓰며, 그 숫자가 일치 범위의 첫 글자일 때만 인정된다.
    risky: Vec<bool>,
}

fn prepare(s: &str, fold_digits: bool, is_pattern: bool) -> Prepared {
    let original: Vec<char> = s.chars().collect();
    let mut folded: Vec<(char, usize)> = Vec::new();
    let mut risky = vec![false; original.len()];
    for (index, &c) in original.iter().enumerate() {
        let after_letter = index > 0 && is_letter(original[index - 1]);
        let mut buffer = Vec::new();
        let digits = digits_of(c).filter(|_| fold_digits && (!is_pattern || (!after_letter && folds_in_pattern(c))));
        match digits {
            Some(digits) => {
                risky[index] = after_letter;
                buffer.extend(digits.chars())
            }
            None => fold_char(c, &mut buffer),
        }
        folded.extend(buffer.into_iter().map(|b| (b, index)));
    }
    let marks = original.iter().map(|c| blocks_end_before(*c)).collect();
    Prepared { chars: nfd_chars(&folded), marks, risky }
}

/// `localizedCaseInsensitiveContains`의 근사. 빈 검색어는 일치하지 않는다(Swift와 같다).
///
/// 숫자 접기를 켠 비교와 끈 비교 중 하나라도 일치하면 일치다(글자 앞에 문자가 있어 접히지 않은 숫자도
/// 같은 글자끼리는 걸리기 때문).
pub fn localized_case_insensitive_contains(haystack: &str, needle: &str) -> bool {
    contains_with(haystack, needle, true) || contains_with(haystack, needle, false)
}

fn contains_with(haystack: &str, needle: &str, fold_digits: bool) -> bool {
    // 검색어에서 십진 숫자(Numeric_Type=Decimal, 전각과 아랍 인도 포함)가 문자보다 먼저 나오면
    // 결합 기호 · 변이 선택자 · ZWJ는 양쪽에서 무시된다(Swift 관찰).
    let numeric = starts_numeric(needle);
    let hay_prepared = prepare(haystack, fold_digits, false);
    let pat_prepared = prepare(needle, fold_digits, true);
    let is_mark = |c: &(char, usize), marks: &[bool]| blocks_end_before(c.0) || marks[c.1];
    let drop = |c: &(char, usize), marks: &[bool]| numeric && (is_mark(c, marks) || c.0 == '\u{200D}');
    let marks = &hay_prepared.marks;
    // (글자, 원래 번호, 스스로 결합 기호인가)
    let hay: Vec<(char, usize, bool)> = hay_prepared
        .chars
        .iter()
        .filter(|c| !drop(c, marks))
        .map(|c| (c.0, c.1, is_mark(c, marks)))
        .collect();
    let pat: Vec<char> = pat_prepared
        .chars
        .iter()
        .filter(|c| !drop(c, &pat_prepared.marks))
        .map(|(c, _)| *c)
        .collect();
    if pat.is_empty() || pat.len() > hay.len() {
        return false;
    }
    (0..=hay.len() - pat.len()).any(|start| {
        let end = start + pat.len();
        let window = &hay[start..end];
        if window.iter().map(|(c, _, _)| *c).ne(pat.iter().copied()) {
            return false;
        }
        // 원래 글자 한가운데서 시작하거나 끝날 수 없다.
        if start > 0 && hay[start].1 == hay[start - 1].1 || end < hay.len() && hay[end].1 == hay[end - 1].1 {
            return false;
        }
        // 문자 바로 뒤에서 접힌 숫자는 일치 범위의 첫 글자일 때만 인정된다.
        if window.iter().any(|(_, tag, _)| hay_prepared.risky[*tag] && *tag > window[0].1) {
            return false;
        }
        // 일치 범위의 마지막 원래 글자 바로 뒤가 결합 기호인가(정규 순서로 바뀌기 전 원래 순서).
        let last_tag = window.iter().map(|(_, tag, _)| *tag).max().unwrap_or(0);
        let follows_mark = !numeric && marks.get(last_tag + 1) == Some(&true);
        let (last, _, _) = hay[end - 1];
        let prev = (end > 1).then(|| hay[end - 2]);
        // ZWJ로 끝나는 일치는 그 뒤에 글자가 이어지면 안 된다(맨 앞의 ZWJ와, 뒤가 글 끝 · 공백 · 문장 부호 · 숫자 ·
        // 이모지인 ZWJ는 예외).
        if last == '\u{200D}' {
            if let (Some((before, _, before_mark)), Some((next, _, _))) = (prev, hay.get(end)) {
                let letter_join = (is_letter(before) || before_mark) && (is_letter(*next) || follows_mark || *next == '\u{200D}');
                let emoji_join = is_emoji_like(before) && is_emoji_like(*next);
                if letter_join || emoji_join {
                    return false;
                }
            }
        }
        let (last, next) = (last as u32, hay.get(end).map(|(c, _, _)| *c as u32));
        // 한글 자모 순서(초성, 중성, 종성)로 앞 글자에 붙는 자모 앞에서는 끝날 수 없다.
        // 따로 적힌 자모는 뒤의 ZWJ나 종성에도 붙는다(풀린 완성형의 마지막 종성은 뒤 종성에 붙지 않는다).
        let is_l = |c: u32| matches!(c, 0x1100..=0x115F | 0xA960..=0xA97C);
        let is_v = |c: u32| matches!(c, 0x1160..=0x11A7 | 0xD7B0..=0xD7C6);
        let is_t = |c: u32| matches!(c, 0x11A8..=0x11FF | 0xD7CB..=0xD7FB);
        let explicit_jamo = (is_l(last) || is_v(last) || is_t(last)) && (end == 1 || hay[end - 2].1 != hay[end - 1].1);
        if numeric {
            // 숫자 규칙에서는 자모 붙임도 따지지 않는 것으로 관찰된다.
        } else if explicit_jamo && next == Some(0x200D) {
            return false;
        }
        if let Some(next) = next.filter(|_| !numeric) {
            if (is_v(next) && (is_l(last) || is_v(last)))
                || (is_t(next) && (is_v(last) || (is_t(last) && explicit_jamo)))
            {
                return false;
            }
        }
        hay.get(end).is_none() || !follows_mark
    })
}

/// 제목, 미리보기, 그룹에서 부분 일치를 찾는다. 빈 검색어는 모두 일치한다.
pub fn matches(summary: &MemoSummary, query: &str) -> bool {
    let needle = trim(query);
    if needle.is_empty() {
        return true;
    }
    [summary.title(), summary.preview.clone(), summary.meta.group.clone().unwrap_or_default()]
        .iter()
        .any(|h| localized_case_insensitive_contains(h, needle))
}

impl FileMemoRepository {
    /// 본문에서 찾는다. 파일을 한 건씩 읽고 바로 버린다 (메모리에 쌓지 않는다).
    /// 메모 폴더에 없으면 휴지통의 파일을 본다. 잠긴 메모는 찾지 않는다.
    pub fn search_bodies(&self, query: &str, ids: &[MemoID]) -> HashSet<MemoID> {
        let needle = trim(query);
        let mut found = HashSet::new();
        if needle.is_empty() {
            return found;
        }
        for id in ids {
            let text = fs::read_to_string(self.memo_file(id))
                .or_else(|_| fs::read_to_string(self.trash_directory(id).join("memo.md")));
            let Ok(text) = text else { continue };
            // 앞머리(color, pinned 등)는 본문이 아니므로 뺀다.
            let Ok(document) = frontmatter::decode(&text) else { continue };
            if document.meta.is_locked {
                continue;
            }
            if localized_case_insensitive_contains(&document.body, needle) {
                found.insert(id.clone());
            }
        }
        found
    }
}
