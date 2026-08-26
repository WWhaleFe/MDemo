import Foundation
import Observation

/// 앱 전체의 단일 진실 공급원 (설계서 §4-3).
///
/// 모든 상태 변경은 이곳을 거친다. UI가 저장소를 직접 호출하지 않는 이유는
/// 리스트 창과 스티키 창이 서로의 변경을 자동으로 보게 만들기 위해서다.
///
/// 메모리 원칙(§4-5): 이 객체가 들고 있는 것은 요약 목록뿐이다.
/// 본문은 `loadBody(id:)`로 필요할 때 읽고, 창이 닫히면 호출자가 버린다.
@MainActor
@Observable
public final class MemoStore {
    public private(set) var summaries: [MemoSummary] = []

    @ObservationIgnored private let repository: any MemoRepository

    public init(repository: any MemoRepository) {
        self.repository = repository
        reloadSummaries()
    }

    public func reloadSummaries() {
        summaries = (try? repository.loadSummaries()) ?? []
    }

    /// 새 메모를 만들고 파일로 저장한다 (KEY-10).
    @discardableResult
    public func createMemo(colorHex: String = MemoColor.presets[0].hex, group: String? = nil) -> MemoMeta {
        let meta = MemoMeta(id: .generate(), group: group, colorHex: colorHex)
        let document = MemoDocument(meta: meta, body: "")
        try? repository.save(document)
        summaries.insert(MemoSummary(meta: meta, preview: ""), at: 0)
        return meta
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

    public func moveToTrash(id: MemoID) {
        try? repository.moveToTrash(id: id)
        summaries.removeAll { $0.id == id }
    }

    /// 재시작 시 다시 띄울 메모들 (WIN-06).
    public var openMemos: [MemoSummary] {
        summaries.filter { $0.meta.isOpen }
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
