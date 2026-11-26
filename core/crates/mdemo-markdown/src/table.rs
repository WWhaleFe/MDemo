//! 표 (Swift `MarkdownTable.swift`, MD-14).
//!
//! 표의 각 줄에 `BlockStyle::TableRow`를 달고 줄 사이의 관계는 이 도우미가 계산한다.
//! 구분 줄(`| --- | --- |`)은 화면에 두지 않고, 저장할 때 첫 줄 뒤에 다시 만들어 넣는다.

use crate::text::{self, chars};

pub const PIPE: &str = "|";

/// 표의 한 줄인가. 세로줄로 시작하는 줄만 표로 본다.
pub fn is_row(line: &str) -> bool {
    let trimmed = text::trim_ws(line);
    text::has_prefix(trimmed, PIPE) && text::count(trimmed) > 1
}

/// `| --- | --- |` 처럼 칸이 모두 줄표인 줄인가.
pub fn is_separator_row(line: &str) -> bool {
    if !is_row(line) {
        return false;
    }
    let cells = cells_of(line);
    if cells.is_empty() {
        return false;
    }
    cells.iter().all(|cell| {
        let body = text::trim_ws(cell);
        if text::count(body) < 3 {
            return false;
        }
        // 정렬 표시(`:---`, `---:`, `:---:`)도 구분 줄이다.
        let core = text::trim_set(body, &[':']);
        !core.is_empty() && chars(core).iter().all(|c| text::ch_eq(c, "-"))
    })
}

/// 줄을 칸 단위로 쪼갠다. 양 끝의 빈 칸(세로줄 바깥)은 버린다.
pub fn cells_of(line: &str) -> Vec<String> {
    let mut parts: Vec<&str> = text::split_char(text::trim_ws(line), PIPE);
    if parts.first().is_some_and(|p| text::trim_ws(p).is_empty()) {
        parts.remove(0);
    }
    if parts.last().is_some_and(|p| text::trim_ws(p).is_empty()) {
        parts.pop();
    }
    parts.into_iter().map(str::to_string).collect()
}

pub fn column_count_of(line: &str) -> usize {
    cells_of(line).len().max(1)
}

/// 저장할 때 첫 줄 뒤에 넣는 구분 줄.
pub fn separator_row(columns: usize) -> String {
    row(&vec!["---".to_string(); columns.max(1)])
}

/// 빈 줄. 새 행을 만들 때 쓴다.
pub fn empty_row(columns: usize) -> String {
    row(&vec![String::new(); columns.max(1)])
}

pub fn row(cells: &[String]) -> String {
    format!("{PIPE} {} {PIPE}", cells.join(&format!(" {PIPE} ")))
}

/// 표를 처음 넣을 때의 뼈대. 첫 줄은 제목 줄이고 이름을 미리 넣어 둔다.
pub fn skeleton(columns: usize, rows: usize) -> Vec<String> {
    let columns = columns.max(1);
    let headers: Vec<String> = (1..=columns)
        .map(|i| if columns == 2 && i == 1 { "항목".to_string() } else if i == 2 { "내용".to_string() } else { format!("제목 {i}") })
        .collect();
    let mut lines = vec![row(&headers)];
    for _ in 1..rows.max(2) {
        lines.push(empty_row(columns));
    }
    lines
}

/// 칸이 비어 있는 줄인가. 빈 줄에서 엔터를 치면 표를 빠져나온다.
pub fn is_empty_row(line: &str) -> bool {
    is_row(line) && cells_of(line).iter().all(|c| text::trim_ws(c).is_empty())
}
