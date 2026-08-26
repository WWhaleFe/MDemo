import Foundation
import MemoCore
import Observation

/// 리스트 창이 보여 줄 것을 정한다 (LST-*, SRC-*, TRS-*).
///
/// 화면 코드에서 조건문을 걷어내기 위해 "무엇을 보여 줄지"는 전부 여기서 계산한다.
/// 덕분에 창을 띄우지 않고도 목록·검색·정렬 동작을 시험할 수 있다.
@MainActor
@Observable
public final class MemoListModel {
    /// 왼쪽에서 고른 항목.
    public enum Scope: Hashable {
        case all
        case group(String)
        case ungrouped
        case trash

        public var title: String {
            switch self {
            case .all: return "전체"
            case .group(let name): return name
            case .ungrouped: return "그룹 없음"
            case .trash: return "휴지통"
            }
        }
    }

    public var scope: Scope = .all
    public var query: String = ""
    public var sortOrder: MemoSortOrder = .newestFirst
    /// 목록에서 고른 메모들 (LST-05).
    public var selection: Set<MemoID> = []

    @ObservationIgnored public let store: MemoStore

    public init(store: MemoStore) {
        self.store = store
    }

    /// 지금 화면에 보여 줄 메모들.
    public var visibleMemos: [MemoSummary] {
        let base: [MemoSummary]
        switch scope {
        case .all:
            base = store.search(query: query)
        case .group(let name):
            base = store.search(query: query, group: name)
        case .ungrouped:
            let ungrouped = store.summaries.filter { $0.meta.group == nil }
            base = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? ungrouped
                : ungrouped.filter { MemoSearch.matches($0, query: query) }
        case .trash:
            let needle = query.trimmingCharacters(in: .whitespaces)
            base = needle.isEmpty ? store.trashed : store.trashed.filter { MemoSearch.matches($0, query: needle) }
        }
        return MemoSearch.sorted(base, by: sortOrder)
    }

    public var isShowingTrash: Bool {
        if case .trash = scope { return true }
        return false
    }

    /// 왼쪽 목록에 표시할 항목들.
    public var sidebarItems: [(scope: Scope, count: Int)] {
        var items: [(Scope, Int)] = [(.all, store.summaries.count)]
        for group in store.groups {
            items.append((.group(group), store.memoCount(inGroup: group)))
        }
        if store.ungroupedCount > 0 || store.groups.isEmpty {
            items.append((.ungrouped, store.ungroupedCount))
        }
        items.append((.trash, store.trashed.count))
        return items
    }

    /// 휴지통을 볼 때만 그 목록을 읽는다. 평소에는 메모리에 두지 않는다 (§4-5).
    public func prepare(for newScope: Scope) {
        scope = newScope
        selection = []
        if case .trash = newScope {
            store.reloadTrash()
        }
    }

    public func refresh() {
        store.reloadSummaries()
        store.reloadGroups()
        if isShowingTrash {
            store.reloadTrash()
        }
    }

    // MARK: - 동작

    public func moveSelectionToTrash() {
        for id in selection {
            store.moveToTrash(id: id)
        }
        selection = []
    }

    public func restoreSelection() {
        for id in selection {
            store.restoreFromTrash(id: id)
        }
        selection = []
    }

    public func deleteSelectionPermanently() {
        for id in selection {
            store.permanentlyDelete(id: id)
        }
        selection = []
    }

    public func assignSelection(to group: String?) {
        for id in selection {
            store.assignGroup(group, to: id)
        }
    }
}
