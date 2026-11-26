//! 파일에 닿는 저장 흐름 (Swift `MemoStore`에서 화면과 암호를 뺀 부분).
//!
//! 요약 목록과 보드 배치를 들고 있고, 저장소 호출 순서와 조용히 넘기는 오류까지 Swift와 같다.
//! 잠긴 메모의 저장 · 영구 삭제는 P4에서 옮긴다. 복제, 흐름, 열림 상태 같은 화면 쪽 기능은
//! 이번 범위가 아니다.

use super::{
    summary::{prefix_characters, MemoSummary, PREVIEW_CHARACTER_LIMIT},
    Clock, FileMemoRepository, IdSource,
};
use crate::{
    board_layout::{BoardLayout, Placement},
    frontmatter::MemoDocument,
    id::MemoID,
    link::{MemoLink, MemoLinkKind},
    meta::{MemoColor, MemoDate, MemoMeta},
};
use std::{collections::{BTreeSet, HashSet}, sync::Arc};

/// 휴지통 보관 하루의 길이. Swift는 달력 기준 일수(`Calendar.current`)로 빼므로
/// 서머타임이 있는 시간대에서는 하루가 23 · 25시간일 수 있다. 여기서는 24시간으로 계산한다.
const DAY: f64 = 86_400.;

pub struct MemoStore {
    repo: FileMemoRepository,
    clock: Arc<dyn Clock>,
    ids: Arc<dyn IdSource>,
    pub summaries: Vec<MemoSummary>,
    pub groups: Vec<String>,
    pub trashed: Vec<MemoSummary>,
    pub board_layout: BoardLayout,
}

impl MemoStore {
    /// `clock`은 저장소에 준 것과 같은 시계를 쓰는 것이 보통이다.
    pub fn new(repo: FileMemoRepository, clock: Arc<dyn Clock>, ids: Arc<dyn IdSource>) -> Self {
        let mut store = Self {
            repo,
            clock,
            ids,
            summaries: Vec::new(),
            groups: Vec::new(),
            trashed: Vec::new(),
            board_layout: BoardLayout::default(),
        };
        store.summaries = store.repo.load_summaries().unwrap_or_default();
        store.reload_groups();
        store.reload_board_layout();
        store
    }

    pub fn repository(&self) -> &FileMemoRepository {
        &self.repo
    }

    pub fn reload_summaries(&mut self) {
        self.summaries = self.repo.load_summaries().unwrap_or_default();
        self.reload_board_layout();
    }

    pub fn reload_groups(&mut self) {
        let saved = self.repo.load_groups();
        // 메모에는 붙어 있는데 목록에 없는 그룹도 보여야 한다.
        let used: BTreeSet<String> = self
            .summaries
            .iter()
            .filter_map(|s| s.meta.group.clone())
            .filter(|g| !saved.contains(g))
            .collect();
        self.groups = saved.into_iter().chain(used).collect();
    }

    pub fn reload_trash(&mut self) {
        self.trashed = self.repo.load_trash_summaries().unwrap_or_default();
    }

    // MARK: - 메모

    /// 새 메모를 만들고 파일로 저장한다. 저장에 실패해도(파기된 ID 등) 요약은 목록에 들어간다.
    pub fn create_memo(&mut self, color_hex: Option<&str>, group: Option<&str>) -> MemoMeta {
        let now = self.clock.now();
        let mut meta = MemoMeta::new(self.ids.next_id(now));
        meta.group = group.map(String::from);
        meta.color_hex = color_hex.unwrap_or(MemoColor::PRESETS[0].1).into();
        meta.created = now;
        meta.modified = now;
        let _ = self.repo.save(&MemoDocument {
            meta: meta.clone(),
            body: String::new(),
            unknown_frontmatter_lines: Vec::new(),
            unknown_link_tokens: Vec::new(),
        });
        self.summaries.insert(0, MemoSummary::new(meta.clone(), String::new()));
        self.normalize_manual_order();
        meta
    }

    pub fn load_document(&self, id: &MemoID) -> Option<MemoDocument> {
        self.repo.load(id).ok()
    }

    /// 본문을 저장하고 요약을 갱신한다. 같은 내용이면 쓰지 않는다 (수정 시각도 그대로).
    pub fn save_body(&mut self, id: &MemoID, body: &str) -> bool {
        let Ok(mut document) = self.repo.load(id) else { return false };
        if document.meta.is_locked {
            // 잠긴 메모는 열쇠 세션이 있어야 한다 (P4).
            return false;
        }
        if document.body == body {
            return true;
        }
        document.body = body.into();
        document.meta.modified = self.clock.now();
        if self.repo.save(&document).is_err() {
            return false;
        }
        self.update_summary(document.meta, prefix_characters(body, PREVIEW_CHARACTER_LIMIT));
        true
    }

    /// 메타데이터만 갱신한다. 바뀐 것이 없으면 쓰지 않는다. 잠금 여부를 바꾸는 변경은 무시한다.
    pub fn update_meta(&mut self, id: &MemoID, transform: impl FnOnce(&mut MemoMeta)) {
        let Ok(mut document) = self.repo.load(id) else { return };
        let before = document.meta.clone();
        transform(&mut document.meta);
        if document.meta.is_locked != before.is_locked || document.meta == before {
            return;
        }
        document.meta.modified = self.clock.now();
        if self.repo.save(&document).is_err() {
            return;
        }
        let preview = if document.meta.is_locked {
            String::new()
        } else {
            prefix_characters(&document.body, PREVIEW_CHARACTER_LIMIT)
        };
        self.update_summary(document.meta, preview);
    }

    fn update_summary(&mut self, meta: MemoMeta, preview: String) {
        let summary = MemoSummary::new(meta, preview);
        match self.summaries.iter().position(|s| s.meta.id == summary.meta.id) {
            Some(index) => self.summaries[index] = summary,
            None => self.summaries.push(summary),
        }
    }

    // MARK: - 보드 배치와 연결

    pub fn reload_board_layout(&mut self) {
        self.board_layout = self.repo.load_board_layout();
        self.normalize_manual_order();
    }

    fn normalize_manual_order(&mut self) {
        let ids: Vec<MemoID> = self.summaries.iter().map(|s| s.meta.id.clone()).collect();
        let order = self.board_layout.normalized_order(&ids);
        if order == self.board_layout.manual_order {
            return;
        }
        self.board_layout.manual_order = order;
        let _ = self.repo.save_board_layout(&self.board_layout);
    }

    /// 자동 정리 결과를 한 번만 기록한다.
    pub fn set_board_placements(&mut self, placements: &[(MemoID, Placement)]) {
        for (id, placement) in placements {
            self.board_layout.placements.insert(id.raw_value.clone(), placement.clone());
        }
        let _ = self.repo.save_board_layout(&self.board_layout);
    }

    /// 한 쌍에는 종류와 방향에 관계없이 연결 하나만 남긴다.
    pub fn link(&mut self, from: &MemoID, to: &MemoID, kind: MemoLinkKind) {
        let find = |s: &Self, id: &MemoID| s.summaries.iter().position(|x| x.meta.id == *id);
        if from == to || find(self, from).is_none() || find(self, to).is_none() {
            return;
        }
        let reverse = find(self, to).is_some_and(|i| self.summaries[i].meta.links.iter().any(|l| l.to == *from));
        if reverse {
            self.update_meta(to, |m| m.links.retain(|l| l.to != *from));
        }
        let previous = find(self, from)
            .and_then(|i| self.summaries[i].meta.links.iter().find(|l| l.to == *to).cloned());
        self.update_meta(from, |m| {
            m.links.retain(|l| l.to != *to);
            let mut link = MemoLink::new(to.clone(), kind, previous.as_ref().map_or("", |p| &p.label));
            link.unknown_suffix = previous.map(|p| p.unknown_suffix).unwrap_or_default();
            m.links.push(link);
        });
    }

    // MARK: - 휴지통

    pub fn move_to_trash(&mut self, ids: &[MemoID]) {
        if ids.is_empty() {
            return;
        }
        for id in ids {
            let _ = self.repo.move_to_trash(id);
        }
        let removed: HashSet<&MemoID> = ids.iter().collect();
        self.summaries.retain(|s| !removed.contains(&s.meta.id));
        self.normalize_manual_order();
        self.reload_trash();
    }

    pub fn restore_from_trash(&mut self, ids: &[MemoID]) {
        if ids.is_empty() {
            return;
        }
        for id in ids {
            let _ = self.repo.restore_from_trash(id);
        }
        self.reload_summaries();
        self.reload_trash();
    }

    /// 휴지통 메모를 영구 삭제한다. 잠긴 메모는 P4 전까지 지우지 못하고 건너뛴다.
    pub fn permanently_delete(&mut self, ids: &[MemoID]) {
        if ids.is_empty() {
            return;
        }
        let mut removed: HashSet<MemoID> = HashSet::new();
        for id in ids {
            let locked = self.trashed.iter().any(|t| t.meta.id == *id && t.meta.is_locked);
            if locked || self.repo.permanently_delete(id).is_err() {
                // 지우지 못한 메모의 연결은 복원을 위해 남긴다 (TRS-04).
                continue;
            }
            removed.insert(id.clone());
        }
        self.reload_summaries();
        let linking: Vec<MemoID> = self
            .summaries
            .iter()
            .filter(|s| s.meta.links.iter().any(|l| removed.contains(&l.to)))
            .map(|s| s.meta.id.clone())
            .collect();
        for id in linking {
            self.update_meta(&id, |m| m.links.retain(|l| !removed.contains(&l.to)));
        }
        self.reload_trash();
    }

    /// 휴지통을 전부 비운다.
    pub fn empty_trash(&mut self) {
        let _ = self.repo.empty_trash(None);
        self.reload_summaries();
        self.reload_trash();
    }

    /// 보관 기간(`days`일)이 지난 항목을 비운다 (TRS-03). `days`가 0 이하면 아무것도 하지 않는다.
    pub fn empty_trash_older_than(&mut self, days: i64, now: MemoDate) {
        if days <= 0 {
            return;
        }
        let cutoff = MemoDate(now.0 - days as f64 * DAY);
        let _ = self.repo.empty_trash(Some(cutoff));
        self.reload_summaries();
        self.reload_trash();
    }
}
