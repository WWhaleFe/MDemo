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
        /// 지금 화면에 떠 있는 메모 (LST-09).
        case visible
        /// 화면에 없는 메모 — 내려 둔 것과 한 번도 열지 않은 것 (LST-09).
        case hidden
        case group(String)
        case ungrouped
        case trash

        public var title: String {
            switch self {
            case .all: return "전체"
            case .visible: return "보이는 메모"
            case .hidden: return "숨겨진 메모"
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
    /// 창을 띄우고 내리고 늘어놓는 일. 실제 구현은 창 계층에서 주입한다.
    @ObservationIgnored public var windowActions: MemoWindowActions

    /// 휴지통 자동 비우기 기한(일). 꺼져 있으면 nil. 휴지통 화면의 안내 문구에 쓴다.
    @ObservationIgnored public var trashRetentionDays: () -> Int? = { nil }

    /// 창이 뜨고 지는 것은 이 모델 바깥에서 벌어진다.
    /// 화면이 다시 그려지도록, 창을 다룬 직후 이 값을 올려 변화를 알린다.
    public private(set) var windowStateRevision = 0

    public init(store: MemoStore, windowActions: MemoWindowActions = .none) {
        self.store = store
        self.windowActions = windowActions
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
        case .visible, .hidden:
            // 창 상태는 저장소가 아니라 창 계층에 있다. 이 값을 읽어 두어야 화면이 다시 그려진다.
            _ = windowStateRevision
            let shouldBeVisible = scope == .visible
            let matching = store.summaries.filter { windowActions.isVisible($0.id) == shouldBeVisible }
            base = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? matching
                : matching.filter { MemoSearch.matches($0, query: query) }
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
    ///
    /// 세 묶음으로 나눈다 — 보기(전체·보이는·숨겨진), 그룹, 휴지통.
    /// 한 줄로 늘어놓으면 성격이 다른 항목이 뒤섞여 무엇을 고르는 것인지 알기 어렵다.
    public var sidebarItems: [(scope: Scope, count: Int)] {
        viewSidebarItems + groupSidebarItems + [(.trash, store.trashed.count)]
    }

    /// 보기 묶음 — 전체 / 보이는 메모 / 숨겨진 메모 (LST-09).
    public var viewSidebarItems: [(scope: Scope, count: Int)] {
        _ = windowStateRevision
        let visibleCount = store.summaries.filter { windowActions.isVisible($0.id) }.count
        return [
            (.all, store.summaries.count),
            (.visible, visibleCount),
            (.hidden, store.summaries.count - visibleCount),
        ]
    }

    /// 그룹 묶음 (LST-02, LST-03).
    public var groupSidebarItems: [(scope: Scope, count: Int)] {
        var items: [(Scope, Int)] = store.groups.map { (.group($0), store.memoCount(inGroup: $0)) }
        if store.ungroupedCount > 0 || store.groups.isEmpty {
            items.append((.ungrouped, store.ungroupedCount))
        }
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
        // 창이 뜨고 진 것도 이때 다시 본다. 창 상태는 이 모델 밖에서 바뀐다.
        noteWindowStateChanged()
    }

    // MARK: - 동작

    /// 고른 메모를 목록에 보이는 차례대로. 여러 개를 다룰 때 순서가 흔들리지 않게 한다.
    public var orderedSelection: [MemoID] {
        visibleMemos.map(\.id).filter { selection.contains($0) }
    }

    /// 우클릭한 줄이 선택에 들어 있으면 선택 전체에, 아니면 그 줄 하나에 적용한다.
    /// Finder와 같은 규칙이다.
    public func targets(for ids: Set<MemoID>) -> [MemoID] {
        visibleMemos.map(\.id).filter { ids.contains($0) }
    }

    public func moveSelectionToTrash() {
        moveToTrash(orderedSelection)
    }

    public func moveToTrash(_ ids: [MemoID]) {
        // 화면에 떠 있던 창은 먼저 내린다. 버린 메모가 화면에 남아 있으면 안 된다.
        windowActions.hide(ids)
        store.moveToTrash(ids: ids)
        selection.subtract(ids)
        noteWindowStateChanged()
    }

    public func restoreSelection() {
        restore(orderedSelection)
    }

    public func restore(_ ids: [MemoID]) {
        store.restoreFromTrash(ids: ids)
        selection.subtract(ids)
    }

    public func deleteSelectionPermanently() {
        deletePermanently(orderedSelection)
    }

    public func deletePermanently(_ ids: [MemoID]) {
        store.permanentlyDelete(ids: ids)
        selection.subtract(ids)
    }

    public func assignSelection(to group: String?) {
        assign(orderedSelection, to: group)
    }

    public func assign(_ ids: [MemoID], to group: String?) {
        for id in ids {
            store.assignGroup(group, to: id)
        }
    }

    /// 지금 보이는 목록을 모두 고른다 (⌘A).
    public func selectAllVisible() {
        selection = Set(visibleMemos.map(\.id))
    }

    // MARK: - 창 조작 (LST-06, LST-09 ~ LST-11)

    /// 지금 목록에 보이는 메모를 모두 화면에 띄운다 (LST-10).
    ///
    /// 창 하나마다 본문이 메모리에 올라오므로(§4-5), 몇 개가 뜨는지는 부르는 쪽이 먼저 확인한다.
    public func showAll() {
        windowActions.open(visibleMemos.map(\.id))
        noteWindowStateChanged()
    }

    /// 떠 있는 창을 모두 화면에서 내린다 (LST-10).
    public func hideAll() {
        windowActions.hide(store.summaries.map(\.id))
        noteWindowStateChanged()
    }

    /// 고른 메모만 띄운다 (LST-10).
    public func showSelection() {
        open(orderedSelection)
    }

    /// 메모 여러 개를 띄운다. 목록에 보이는 차례 그대로 띄워야 나열했을 때 순서가 뒤집히지 않는다.
    public func open(_ ids: [MemoID]) {
        guard !ids.isEmpty else { return }
        windowActions.open(ids)
        noteWindowStateChanged()
    }

    /// 한 줄의 눈 아이콘 (LST-10).
    public func toggleVisibility(of id: MemoID) {
        if windowActions.isVisible(id) {
            windowActions.hide([id])
        } else {
            windowActions.open([id])
        }
        noteWindowStateChanged()
    }

    public func arrangeWindows(byGroup: Bool) {
        windowActions.arrange(byGroup)
        noteWindowStateChanged()
    }

    /// 한 번에 띄우면 곤란할 만큼 많은가. 리스트 창이 확인을 받을지 정하는 데 쓴다.
    public static let bulkOpenWarningThreshold = 20

    public var needsBulkOpenConfirmation: Bool {
        visibleMemos.count > Self.bulkOpenWarningThreshold
    }

    /// 창이 뜨거나 진 뒤에 부른다. 이 값이 바뀌어야 목록과 왼쪽 개수가 다시 그려진다.
    public func noteWindowStateChanged() {
        windowStateRevision &+= 1
    }
}
