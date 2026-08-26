import Foundation

/// 메모를 찾는 방법 (SRC-01, SRC-02, SRC-03).
///
/// 검색과 정렬 규칙은 화면과 떼어 놓는다. 창을 띄우지 않고도 시험할 수 있어야
/// "왜 이 메모가 안 나오지" 같은 문제를 빨리 잡을 수 있다.
public enum MemoSortKey: String, CaseIterable, Sendable {
    case modified
    case created
    case title

    public var label: String {
        switch self {
        case .modified: return "수정일"
        case .created: return "생성일"
        case .title: return "제목"
        }
    }
}

public struct MemoSortOrder: Hashable, Sendable {
    public var key: MemoSortKey
    public var ascending: Bool

    public init(key: MemoSortKey = .modified, ascending: Bool = false) {
        self.key = key
        self.ascending = ascending
    }

    public static let newestFirst = MemoSortOrder(key: .modified, ascending: false)
}

public enum MemoSearch {
    /// 제목과 미리보기에서 부분 일치를 찾는다 (SRC-01).
    ///
    /// 대소문자를 구분하지 않고, 한글은 그대로 비교한다.
    /// 본문 전체 검색은 파일을 읽어야 하므로 저장소가 맡는다 — 여기서는 메모리에 있는 것만 본다.
    public static func matches(_ summary: MemoSummary, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }

        let haystacks = [summary.title, summary.preview, summary.meta.group ?? ""]
        return haystacks.contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// 정렬 (SRC-03).
    public static func sorted(_ summaries: [MemoSummary], by order: MemoSortOrder) -> [MemoSummary] {
        summaries.sorted { left, right in
            let result: Bool
            switch order.key {
            case .modified:
                result = left.meta.modified < right.meta.modified
            case .created:
                result = left.meta.created < right.meta.created
            case .title:
                // 한글과 영문이 섞여도 사람이 기대하는 순서로 (SRC-03)
                result = left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
            return order.ascending ? result : !result
        }
    }

    /// 그룹으로 범위를 좁힌다 (SRC-02, LST-03).
    public static func filtered(_ summaries: [MemoSummary], group: String?) -> [MemoSummary] {
        guard let group else { return summaries }
        return summaries.filter { $0.meta.group == group }
    }
}
