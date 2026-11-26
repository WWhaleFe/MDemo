//! 이미지를 "다른 이름으로 저장"할 때 처음 보여 줄 파일 이름 (Swift `ImageSaveName.swift`).
//!
//! 첨부 파일의 실제 이름은 무작위 글자(a1b2c3d4)라 사람이 알아볼 수 없다.
//! 설명(alt)이 있으면 그것을, 없으면 "<메모 제목> 이미지 N"을 쓴다.

use crate::text::{self, chars};

/// 파일 이름에 쓸 수 없는 글자(`/` `:` 줄바꿈 등)를 `-`로 바꾸고 앞뒤 공백과 점을 뗀다.
pub fn sanitized(input: &str) -> String {
    const FORBIDDEN: [&str; 4] = ["/", ":", "\\", "\0"];
    let replaced: String = chars(input)
        .into_iter()
        .map(|c| if FORBIDDEN.iter().any(|f| text::ch_eq(c, f)) || text::is_newline(c) { "-" } else { c })
        .collect();
    text::trim_set(text::trim_ws(&replaced), &['.']).to_string()
}

/// - `alt`: 이미지 설명. 비었으면 제목과 번호로 이름을 만든다.
/// - `memo_title`: 메모 제목. 없으면 "메모"로 쓴다.
/// - `ordinal`: 그 메모 안에서 몇 번째 이미지인가 (1부터).
/// - `file_extension`: 점 없는 확장자. 비면 확장자를 붙이지 않는다.
pub fn default_name(alt: &str, memo_title: Option<&str>, ordinal: i64, file_extension: &str) -> String {
    let mut base = sanitized(alt);
    if base.is_empty() {
        let title = sanitized(memo_title.unwrap_or(""));
        base = format!("{} 이미지 {}", if title.is_empty() { "메모" } else { &title }, ordinal.max(1));
    }
    if file_extension.is_empty() { base } else { format!("{base}.{file_extension}") }
}
