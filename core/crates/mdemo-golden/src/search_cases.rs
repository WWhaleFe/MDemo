//! 본문 검색 일치 비교 (Swift `SearchCases.swift`와 같은 출력): `[[matches, searchBodies], ...]` 한 줄 JSON.

use mdemo_core::{
    frontmatter::MemoDocument,
    id::MemoID,
    meta::{MemoDate, MemoMeta},
    store::{search, FileMemoRepository, MemoSummary, SystemClock},
};
use serde_json::Value;
use std::{error::Error, fs, path::Path, sync::Arc};

pub fn run(cases_file: &Path, root: &Path) -> Result<String, Box<dyn Error>> {
    let value: Value = serde_json::from_slice(&fs::read(cases_file)?)?;
    let cases = value.get("cases").and_then(Value::as_array).ok_or("search-cases 형식 오류")?;
    let repo = FileMemoRepository::new(root, Arc::new(SystemClock))?;
    let id = MemoID::new("01ARZ3NDEKTSV4RRFFQ69G5F00");
    let mut rows = Vec::new();
    for item in cases {
        let body = item.get("body").and_then(Value::as_str).ok_or("body 없음")?;
        let query = item.get("query").and_then(Value::as_str).ok_or("query 없음")?;
        let mut meta = MemoMeta::new(id.clone());
        meta.created = MemoDate(123.25);
        meta.modified = MemoDate(123.25);
        let via_summary = search::matches(&MemoSummary::new(meta.clone(), body.into()), query);
        repo.save(&MemoDocument {
            meta,
            body: body.into(),
            unknown_frontmatter_lines: vec![],
            unknown_link_tokens: vec![],
        })?;
        let via_body = repo.search_bodies(query, std::slice::from_ref(&id)).contains(&id);
        rows.push(format!("[{via_summary},{via_body}]"));
    }
    Ok(format!("[{}]\n", rows.join(",")))
}
