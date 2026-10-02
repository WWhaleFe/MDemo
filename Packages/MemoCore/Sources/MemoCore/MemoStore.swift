import Foundation
import Observation

/// 앱 전체의 단일 진실 공급원 (설계서 §4-3).
///
/// 모든 상태 변경은 이곳을 거친다. UI가 저장소를 직접 호출하지 않는 이유는
/// 리스트 창과 스티키 창이 서로의 변경을 자동으로 보게 만들기 위해서다.
///
/// 메모리 원칙(§4-5): 이 객체가 들고 있는 것은 요약 목록뿐이다.
/// 본문은 `loadDocument(id:)`로 필요할 때 읽고, 창이 닫히면 호출자가 버린다.
@MainActor
@Observable
public final class MemoStore {
    public private(set) var summaries: [MemoSummary] = []
    /// 그룹 목록 (LST-02). 메모에 붙은 그룹 이름과 별개로 빈 그룹도 남길 수 있어야 한다.
    public private(set) var groups: [String] = []
    /// 휴지통 목록. 리스트 창에서 휴지통을 볼 때만 채운다 (TRS-02).
    public private(set) var trashed: [MemoSummary] = []

    @ObservationIgnored private let repository: any MemoRepository

    public init(repository: any MemoRepository) {
        self.repository = repository
        reloadSummaries()
        reloadGroups()
    }

    public func reloadSummaries() {
        summaries = (try? repository.loadSummaries()) ?? []
    }

    public func reloadGroups() {
        let saved = (try? repository.loadGroups()) ?? []
        // 메모에는 붙어 있는데 목록에 없는 그룹도 보여야 한다 (다른 기기에서 만든 경우 등).
        let used = Set(summaries.compactMap(\.meta.group)).subtracting(saved)
        groups = saved + used.sorted()
    }

    public func reloadTrash() {
        trashed = (try? repository.loadTrashSummaries()) ?? []
    }

    // MARK: - 메모

    /// 새 메모를 만들고 파일로 저장한다 (KEY-10).
    @discardableResult
    public func createMemo(colorHex: String = MemoColor.presets[0].hex, group: String? = nil) -> MemoMeta {
        let meta = MemoMeta(id: .generate(), group: group, colorHex: colorHex)
        let document = MemoDocument(meta: meta, body: "")
        try? repository.save(document)
        summaries.insert(MemoSummary(meta: meta, preview: ""), at: 0)
        return meta
    }

    /// 밖에서 만든 문서를 그대로 들여온다 (DAT-07).
    public func importDocument(_ document: MemoDocument) {
        try? repository.save(document)
        summaries.insert(
            MemoSummary(meta: document.meta, preview: String(document.body.prefix(200))),
            at: 0
        )
    }

    /// 창을 열 때만 호출한다. 본문 전체를 읽는 유일한 경로다.
    public func loadDocument(id: MemoID) -> MemoDocument? {
        try? repository.load(id: id)
    }

    /// 본문을 저장하고 요약을 갱신한다. 호출자가 디바운스한다 (DAT-03).
    public func saveBody(id: MemoID, body: String) {
        guard var document = try? repository.load(id: id) else { return }
        document.body = body
        document.meta.modified = Date()
        try? repository.save(document)
        updateSummary(meta: document.meta, preview: String(body.prefix(200)))
    }

    /// 메타데이터만 갱신한다 (색상·투명도·열림 상태 등).
    public func updateMeta(id: MemoID, _ transform: (inout MemoMeta) -> Void) {
        guard var document = try? repository.load(id: id) else { return }
        transform(&document.meta)
        document.meta.modified = Date()
        try? repository.save(document)
        updateSummary(meta: document.meta, preview: String(document.body.prefix(200)))
    }

    /// 창 열림 상태를 기록한다. 이 값이 기기 간 미러링의 근거가 된다 (SYNC-08).
    public func setOpen(id: MemoID, isOpen: Bool) {
        updateMeta(id: id) { $0.isOpen = isOpen }
    }

    /// 재시작 시 다시 띄울 메모들 (WIN-06).
    public var openMemos: [MemoSummary] {
        summaries.filter { $0.meta.isOpen }
    }

    // MARK: - 그룹 (LST-02, LST-03)

    public func createGroup(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !groups.contains(trimmed) else { return }
        groups.append(trimmed)
        try? repository.saveGroups(groups)
    }

    public func renameGroup(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, oldName != trimmed else { return }

        groups = groups.map { $0 == oldName ? trimmed : $0 }
        try? repository.saveGroups(groups)

        // 그 그룹에 속한 메모들의 이름표도 함께 바꾼다.
        for summary in summaries where summary.meta.group == oldName {
            updateMeta(id: summary.id) { $0.group = trimmed }
        }
    }

    /// 그룹만 지운다. 안에 있던 메모는 "그룹 없음"으로 남는다 — 메모를 잃지 않는 쪽을 택한다.
    public func deleteGroup(_ name: String) {
        groups.removeAll { $0 == name }
        try? repository.saveGroups(groups)

        for summary in summaries where summary.meta.group == name {
            updateMeta(id: summary.id) { $0.group = nil }
        }
    }

    public func assignGroup(_ group: String?, to id: MemoID) {
        updateMeta(id: id) { $0.group = group }
    }

    /// 그룹별 메모 개수. 목록 옆에 숫자를 보여 줄 때 쓴다.
    public func memoCount(inGroup group: String?) -> Int {
        guard let group else { return summaries.count }
        return summaries.count { $0.meta.group == group }
    }

    public var ungroupedCount: Int {
        summaries.count { $0.meta.group == nil }
    }

    // MARK: - 휴지통 (TRS-*)

    public func moveToTrash(id: MemoID) {
        moveToTrash(ids: [id])
    }

    /// 여러 개를 한 번에 버린다 (LST-05). 목록은 끝에 한 번만 다시 읽는다.
    public func moveToTrash(ids: [MemoID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            try? repository.moveToTrash(id: id)
        }
        let removed = Set(ids)
        summaries.removeAll { removed.contains($0.id) }
        reloadTrash()
    }

    public func restoreFromTrash(id: MemoID) {
        restoreFromTrash(ids: [id])
    }

    public func restoreFromTrash(ids: [MemoID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            try? repository.restoreFromTrash(id: id)
        }
        reloadSummaries()
        reloadTrash()
    }

    public func permanentlyDelete(id: MemoID) {
        permanentlyDelete(ids: [id])
    }

    public func permanentlyDelete(ids: [MemoID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            try? repository.permanentlyDelete(id: id)
        }
        reloadTrash()
    }

    public func emptyTrash() {
        try? repository.emptyTrash(deletedBefore: nil)
        reloadTrash()
    }

    /// 보관 기간이 지난 항목을 자동으로 비운다 (TRS-03). 앱 시작 시 한 번 호출한다.
    public func emptyTrash(olderThan days: Int) {
        guard days > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        try? repository.emptyTrash(deletedBefore: cutoff)
        reloadTrash()
    }

    // MARK: - 검색 (SRC-01, SRC-02)

    /// 제목·미리보기로 먼저 거르고, 필요하면 본문까지 찾아본다.
    ///
    /// 본문 검색은 파일을 읽어야 해서 비싸다. 앞단계에서 걸린 메모는 다시 읽지 않고,
    /// 걸리지 않은 메모만 파일을 열어 본다.
    public func search(query: String, group: String? = nil, includeBodies: Bool = true) -> [MemoSummary] {
        let scope = MemoSearch.filtered(summaries, group: group)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return scope }

        let quickHits = scope.filter { MemoSearch.matches($0, query: needle) }
        guard includeBodies else { return quickHits }

        let quickHitIDs = Set(quickHits.map(\.id))
        let remaining = scope.filter { !quickHitIDs.contains($0.id) }
        guard !remaining.isEmpty else { return quickHits }

        let bodyHits = (try? repository.searchBodies(matching: needle, in: remaining.map(\.id))) ?? []
        guard !bodyHits.isEmpty else { return quickHits }

        return scope.filter { quickHitIDs.contains($0.id) || bodyHits.contains($0.id) }
    }

    private func updateSummary(meta: MemoMeta, preview: String) {
        let summary = MemoSummary(meta: meta, preview: preview)
        if let index = summaries.firstIndex(where: { $0.id == meta.id }) {
            summaries[index] = summary
        } else {
            summaries.append(summary)
        }
    }
}
