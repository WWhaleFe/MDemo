use crate::{frontmatter::trim, meta::{MemoDate, MemoMeta}};
use unicode_segmentation::UnicodeSegmentation;

/// 목록 미리보기 글자 수 (Swift `previewCharacterLimit`).
pub const PREVIEW_CHARACTER_LIMIT: usize = 200;

/// 메모 한 건의 요약 (Swift `MemoSummary`).
#[derive(Clone, Debug, PartialEq)]
pub struct MemoSummary {
    pub meta: MemoMeta,
    pub preview: String,
    /// 휴지통 목록에서만 값이 있다 (TRS-03).
    pub deleted_at: Option<MemoDate>,
}

/// 앞에서 `count`글자(자소 묶음 기준, Swift `Character`)까지.
pub fn prefix_characters(text: &str, count: usize) -> String {
    text.graphemes(true).take(count).collect()
}

impl MemoSummary {
    /// 잠긴 메모의 미리보기는 비운다.
    pub fn new(meta: MemoMeta, preview: String) -> Self {
        let preview = if meta.is_locked { String::new() } else { preview };
        Self { meta, preview, deleted_at: None }
    }

    /// 목록에 보일 제목. 직접 붙인 제목, 없으면 본문 첫 줄 (TXT-05, TXT-06).
    pub fn title(&self) -> String {
        const EMPTY: &str = "제목 없는 메모";
        if let Some(given) = &self.meta.title {
            if !trim(given).is_empty() {
                return given.clone();
            }
        }
        if self.meta.is_locked {
            return EMPTY.into();
        }
        let first = self
            .preview
            .split('\n')
            .find(|line| {
                let line = trim(line);
                !line.is_empty() && !(line.starts_with("![") && line.ends_with(')'))
            })
            .unwrap_or("");
        // "# "와 공백류를 양끝에서 걷어 낸다.
        let mut cleaned = first;
        loop {
            let next = trim(cleaned).trim_matches(|c| c == '#' || c == ' ');
            if next == cleaned {
                break;
            }
            cleaned = next;
        }
        if cleaned.is_empty() { EMPTY.into() } else { cleaned.into() }
    }
}
