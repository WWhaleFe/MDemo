import Foundation

/// 메모 한 건의 요약. 목록 표시에 필요한 최소한만 담는다.
///
/// 메모리 원칙(§4-5): 앱이 상시 들고 있는 것은 이 요약뿐이고,
/// 본문 전체는 창이 열린 메모만 가진다. 메모가 1,000개여도 상주 메모리는 거의 늘지 않는다.
public struct MemoSummary: Equatable, Sendable, Identifiable {
    public var meta: MemoMeta
    /// 목록에 보여줄 앞부분 발췌.
    public var preview: String
    /// 휴지통에 들어간 시각. 휴지통 목록에서만 값이 있다 (TRS-03).
    public var deletedAt: Date?

    public var id: MemoID { meta.id }

    public init(meta: MemoMeta, preview: String, deletedAt: Date? = nil) {
        self.meta = meta
        self.preview = preview
        self.deletedAt = deletedAt
    }

    /// 본문 첫 줄을 제목으로 삼는다 (TXT-05: 제목과 본문 분리).
    public var title: String {
        let firstLine = preview
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return cleaned.isEmpty ? "제목 없는 메모" : cleaned
    }
}

/// 저장소 인터페이스.
///
/// 구현을 갈아끼울 수 있게 프로토콜로 둔다.
/// 지금은 로컬 파일(`FileMemoRepository`) 하나뿐이지만,
/// 유료 계정 확보 후 실시간 동기화(SYNC-10)나 자체 서버(FUT-02)로 확장할 때
/// 상위 계층을 고치지 않기 위한 경계다.
public protocol MemoRepository: Sendable {
    /// 목록용 요약을 모두 읽는다. 본문 전체는 읽지 않는다.
    func loadSummaries() throws -> [MemoSummary]
    /// 본문까지 포함해 한 건을 읽는다. 창을 열 때만 호출한다.
    func load(id: MemoID) throws -> MemoDocument
    /// 원자적으로 저장한다 (DAT-08).
    func save(_ document: MemoDocument) throws
    /// 휴지통으로 옮긴다 (TRS-01). 파일은 남는다.
    func moveToTrash(id: MemoID) throws
    /// 첨부 이미지를 넣을 폴더 (IMG-07).
    func attachmentsDirectory(for id: MemoID) -> URL

    // MARK: - 휴지통 (TRS-*)

    /// 휴지통에 있는 메모 목록 (TRS-02).
    func loadTrashSummaries() throws -> [MemoSummary]
    /// 휴지통에서 원래 자리로 되돌린다 (TRS-02).
    func restoreFromTrash(id: MemoID) throws
    /// 첨부까지 함께 영구 삭제한다 (TRS-04, TRS-05).
    func permanentlyDelete(id: MemoID) throws
    /// 지정한 날짜보다 오래된 항목을 비운다. nil이면 전부 비운다 (TRS-03, TRS-04).
    func emptyTrash(deletedBefore date: Date?) throws

    // MARK: - 그룹 (LST-02)

    func loadGroups() throws -> [String]
    func saveGroups(_ groups: [String]) throws

    // MARK: - 검색 (SRC-01)

    /// 본문에서 찾는다. 파일을 한 건씩 열어 보고 바로 버려 메모리에 쌓지 않는다.
    func searchBodies(matching query: String, in ids: [MemoID]) throws -> Set<MemoID>
}
