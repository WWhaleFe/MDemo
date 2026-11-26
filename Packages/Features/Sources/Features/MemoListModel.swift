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
        /// 화면에 없는 메모 - 내려 둔 것과 한 번도 열지 않은 것 (LST-09).
        case hidden
        case group(String)
        case ungrouped
        case trash
        case flow(MemoID)

        public var title: String {
            switch self {
            case .all: return "모든 메모"
            case .visible: return "화면에 뜬 메모"
            case .hidden: return "내려 둔 메모"
            case .group(let name): return name
            case .ungrouped: return "미분류"
            case .trash: return "휴지통"
            case .flow: return "흐름"
            }
        }
    }

    public var scope: Scope = .all
    /// 목록에서 메모를 열지 않고 AirDrop 사진을 받는 중이면 그 세션 (받기 띠가 보여 준다).
    public var airDrop: ListAirDropSession?
    /// 검색칸에 친 글자. 찾기에는 `appliedQuery`를 쓴다.
    public var query: String = "" {
        didSet { queryDidChange() }
    }
    /// 실제로 찾는 데 쓰는 검색어. 입력이 0.15초 멈춘 뒤에 `query`를 따라간다.
    public private(set) var appliedQuery: String = ""
    /// 입력 뒤 찾기까지 기다리는 시간(초). 0이면 바로 찾는다(시험용).
    @ObservationIgnored public var searchDebounce: Double = 0.15
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// 찾는 범위. 다음 실행에도 이어진다.
    public var searchTarget: MemoSearchTarget = {
        UserDefaults.standard.string(forKey: "memoList.searchTarget").flatMap(MemoSearchTarget.init(rawValue:)) ?? .titleAndBody
    }() {
        didSet { UserDefaults.standard.set(searchTarget.rawValue, forKey: "memoList.searchTarget") }
    }

    /// 검색을 좁히는 그룹. 저장하지 않는다.
    public enum SearchGroup: Hashable {
        case any
        case ungrouped
        case named(String)
    }
    public var searchGroup: SearchGroup = .any

    /// 찾는 범위나 그룹이 기본값에서 벗어났는가.
    public var hasCustomSearchOptions: Bool { searchTarget != .titleAndBody || searchGroup != .any }

    public func resetSearchOptions() {
        searchTarget = .titleAndBody
        searchGroup = .any
    }

    private func queryDidChange() {
        debounceTask?.cancel()
        debounceTask = nil
        // 지울 때와 시간이 0일 때는 기다리지 않는다.
        if query.trimmingCharacters(in: .whitespaces).isEmpty || searchDebounce <= 0 {
            if appliedQuery != query { appliedQuery = query }
            return
        }
        let delay = searchDebounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.appliedQuery != self.query { self.appliedQuery = self.query }
        }
    }
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

    private struct VisibleKey: Equatable {
        var scope: Scope
        var query: String
        var searchTarget: MemoSearchTarget
        var searchGroup: SearchGroup
        var sortOrder: MemoSortOrder
        var summaries: [MemoSummary]
        var trashed: [MemoSummary]
        var revision: Int
        var manualOrder: [MemoID]
    }
    @ObservationIgnored private var visibleCache: (key: VisibleKey, memos: [MemoSummary])?

    /// 지금 화면에 보여 줄 메모들. 한 번 그릴 때 여러 번 불리므로 같은 입력이면 이전 결과를 돌려준다.
    public var visibleMemos: [MemoSummary] {
        // 캐시를 쓰더라도 관찰 값은 모두 읽어야 화면이 다시 그려진다.
        let key = VisibleKey(scope: scope, query: appliedQuery, searchTarget: searchTarget, searchGroup: searchGroup,
                             sortOrder: sortOrder, summaries: store.summaries, trashed: store.trashed, revision: windowStateRevision, manualOrder: store.boardLayout.manualOrder)
        if let visibleCache, visibleCache.key == key { return visibleCache.memos }
        let memos = computeVisibleMemos()
        visibleCache = (key, memos)
        return memos
    }

    private func computeVisibleMemos() -> [MemoSummary] {
        // 1) 왼쪽 범위 2) 그룹 3) 검색어 순서로 거른다. 모든 범위에서 같은 규칙이다.
        var base: [MemoSummary]
        switch scope {
        case .all:
            base = store.summaries
        case .group(let name):
            base = MemoSearch.filtered(store.summaries, group: name)
        case .ungrouped:
            base = store.summaries.filter { $0.meta.group == nil }
        case .visible, .hidden:
            // 창 상태는 저장소가 아니라 창 계층에 있다. 이 값을 읽어 두어야 화면이 다시 그려진다.
            _ = windowStateRevision
            let shouldBeVisible = scope == .visible
            base = store.summaries.filter { windowActions.isVisible($0.id) == shouldBeVisible }
        case .flow(let id):
            guard let flow = linkIndex.flows.first(where: { $0.id == id }) else { return [] }
            let byID = Dictionary(uniqueKeysWithValues: store.summaries.map { ($0.id, $0) })
            base = flow.memoIDs.compactMap { byID[$0] }
        case .trash:
            base = store.trashed
        }
        switch searchGroup {
        case .any: break
        case .ungrouped: base = base.filter { $0.meta.group == nil }
        case .named(let name): base = base.filter { $0.meta.group == name }
        }
        base = store.filter(base, query: appliedQuery, target: searchTarget)
        // 흐름은 흐름 순서를 지킨다.
        if case .flow = scope { return base }
        if sortOrder.key == .manual, !isShowingTrash {
            let byID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
            return store.boardLayout.normalizedOrder(among: store.summaries.map(\.id)).compactMap { byID[$0] }
        }
        return MemoSearch.sorted(base, by: sortOrder.key == .manual ? .newestFirst : sortOrder)
    }

    public var canReorder: Bool {
        if case .flow = scope { return false }
        return !isShowingTrash
    }

    /// 목적지는 이동 전 보이는 목록의 틈 번호다. 거른 범위 밖의 자리는 그대로 둔다.
    public func reorder(_ ids: Set<MemoID>, to destination: Int) {
        guard canReorder else { return }
        let visible = visibleMemos.map(\.id)
        let moving = visible.filter { ids.contains($0) }
        guard !moving.isEmpty else { return }
        let gap = max(0, min(destination, visible.count))
        var remaining = visible.filter { !ids.contains($0) }
        let insertion = visible.prefix(gap).filter { !ids.contains($0) }.count
        remaining.insert(contentsOf: moving, at: insertion)
        guard remaining != visible else { return }
        var global = store.boardLayout.normalizedOrder(among: store.summaries.map(\.id))
        let included = Set(visible)
        // 정렬을 처음 바꿀 때도 지금 보이는 차례를 출발점으로 삼는다.
        var replacement = remaining.makeIterator()
        for i in global.indices where included.contains(global[i]) { global[i] = replacement.next()! }
        store.setManualOrder(global)
        sortOrder = MemoSortOrder(key: .manual)
    }

    public func moveByKeyboard(_ id: MemoID, direction: Int) {
        let visible = visibleMemos.map(\.id)
        let ids = selection.contains(id) ? selection : [id]
        let offsets = visible.indices.filter { ids.contains(visible[$0]) }
        guard let first = offsets.first, let last = offsets.last else { return }
        if direction < 0, first > 0 { reorder(ids, to: first - 1) }
        if direction > 0, last + 1 < visible.count { reorder(ids, to: last + 2) }
    }

    public var isShowingTrash: Bool {
        if case .trash = scope { return true }
        return false
    }

    /// 왼쪽 목록에 표시할 항목들.
    ///
    /// 세 묶음으로 나눈다 - 보기(전체·보이는·숨겨진), 그룹, 휴지통.
    /// 한 줄로 늘어놓으면 성격이 다른 항목이 뒤섞여 무엇을 고르는 것인지 알기 어렵다.
    public var sidebarItems: [(scope: Scope, count: Int)] {
        viewSidebarItems + groupSidebarItems + [(.trash, store.trashed.count)]
    }

    /// 보기 묶음 - 전체 / 보이는 메모 / 숨겨진 메모 (LST-09).
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
        store.reloadBoardLayout()
        if isShowingTrash {
            store.reloadTrash()
        }
        pruneCaches()
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

    public func canDuplicate(_ ids: [MemoID]) -> Bool {
        !isShowingTrash && !ids.isEmpty && ids.allSatisfy { id in
            store.summaries.contains { $0.id == id && !$0.meta.isLocked }
        }
    }

    /// 화면에 보이는 기본 자리를 저장한 뒤 복제하고 새 메모를 선택한다.
    public func duplicate(_ ids: [MemoID]) {
        guard canDuplicate(ids) else { return }
        let positions = boardPlacements(for: visibleMemos)
        let missing = ids.filter { store.boardLayout.placement(for: $0) == nil }
        store.setBoardPlacements(Dictionary(uniqueKeysWithValues: Set(missing).compactMap { id in
            positions[id].map { (id, $0) }
        }))
        let copies = store.duplicate(ids)
        guard !copies.isEmpty else { return }
        // 복제본은 창과 연결이 없으므로 이 두 보기에서는 전체 목록으로 옮긴다.
        if scope == .visible { scope = .all }
        if case .flow = scope { scope = .all }
        selection = Set(copies)
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

    public enum ViewMode: String, CaseIterable {
        case list, grid, bento, board
        public var label: String {
            switch self {
            case .list: "목록"
            case .grid: "그리드"
            case .bento: "벤토"
            case .board: "보드"
            }
        }
        public var symbol: String {
            switch self {
            case .list: "list.bullet"
            case .grid: "square.grid.2x2"
            case .bento: "rectangle.3.group"
            case .board: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    public struct LinkIndex {
        public var edges: [MemoEdge] = []
        public var flows: [MemoFlow] = []
        public var flowByMemo: [MemoID: (flow: MemoFlow, index: Int)] = [:]
        public var linkCount: [MemoID: Int] = [:]
        public var summaries: [MemoID: MemoSummary] = [:]
        public var countsByKind: [MemoID: [MemoLinkKind: Int]] = [:]
        public func kindCounts(of id: MemoID) -> [MemoLinkKind: Int] { countsByKind[id] ?? [:] }
        public func title(of flow: MemoFlow) -> String { summaries[flow.id]?.title ?? "흐름" }
    }

    @ObservationIgnored private var indexedSummaries: [MemoSummary]?
    @ObservationIgnored private var cachedLinks = LinkIndex()

    /// 연결 계산은 요약이 바뀔 때만 수행한다. 카드는 이 인덱스를 공유한다.
    public var linkIndex: LinkIndex {
        let summaries = store.summaries
        if indexedSummaries != summaries {
            var index = LinkIndex()
            index.edges = store.edges
            index.flows = store.flows
            index.summaries = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
            for edge in index.edges {
                index.linkCount[edge.from, default: 0] += 1
                index.linkCount[edge.to, default: 0] += 1
                index.countsByKind[edge.from, default: [:]][edge.kind, default: 0] += 1
                index.countsByKind[edge.to, default: [:]][edge.kind, default: 0] += 1
            }
            for flow in index.flows {
                for (offset, id) in flow.memoIDs.enumerated() { index.flowByMemo[id] = (flow, offset) }
            }
            indexedSummaries = summaries
            cachedLinks = index
        }
        return cachedLinks
    }

    public var scopeTitle: String {
        if case .flow(let id) = scope, let flow = linkIndex.flows.first(where: { $0.id == id }) {
            return linkIndex.title(of: flow)
        }
        return scope.title
    }

    public var flowSidebarItems: [(scope: Scope, title: String, count: Int)] {
        let index = linkIndex
        return index.flows.map { (.flow($0.id), index.title(of: $0), $0.memoIDs.count) }
    }

    public func flowContext(of id: MemoID) -> (flow: MemoFlow, index: Int)? { linkIndex.flowByMemo[id] }

    // MARK: - 카드 정보 캐시

    /// 카드 한 장을 그리는 데 필요한, 메모 본문에서 뽑은 값.
    public struct CardInfo {
        public struct Task { public var text: String; public var checked: Bool }
        /// 마크다운 기호를 걷어 낸 여러 줄 미리보기.
        public var preview = ""
        /// 목록 줄에 쓰는 한 줄 미리보기.
        public var singleLinePreview = ""
        /// 체크리스트 항목. 글은 기호를 걷어 낸 것이다.
        public var tasks: [Task] = []
        public var total: Int { tasks.count }
        public var done: Int { tasks.filter(\.checked).count }
    }

    private struct CardKey: Hashable {
        var modified: Date
        var previewHash: Int
    }
    @ObservationIgnored private var cardCache: [MemoID: (key: CardKey, info: CardInfo)] = [:]
    /// 카드 정보를 새로 계산한 횟수. 캐시가 듣는지 시험에서 확인한다.
    @ObservationIgnored private(set) var cardInfoComputations = 0

    /// 수정 시각과 미리보기가 같으면 이전에 계산한 값을 돌려준다. 바뀐 메모만 다시 계산한다.
    public func cardInfo(for memo: MemoSummary) -> CardInfo {
        if memo.meta.isLocked { return CardInfo(preview: "잠긴 메모", singleLinePreview: "잠긴 메모", tasks: []) }
        let key = CardKey(modified: memo.meta.modified, previewHash: memo.preview.hashValue)
        if let cached = cardCache[memo.id], cached.key == key { return cached.info }
        cardInfoComputations += 1
        let info = CardInfo(
            preview: cleanedMemoPreview(memo.preview),
            singleLinePreview: cleanedMemoPreview(memo.preview, singleLine: true),
            tasks: Self.checklist(memo).map { .init(text: cleanedMemoPreview($0.text, excludingTitle: false), checked: $0.checked) })
        cardCache[memo.id] = (key, info)
        return info
    }

    /// 요약 목록에 없는 메모의 캐시는 버린다. 캐시가 메모 수만큼만 남게 한다.
    private func pruneCaches() {
        let alive = Set(store.summaries.map(\.id)).union(store.trashed.map(\.id))
        cardCache = cardCache.filter { alive.contains($0.key) }
    }

    // MARK: - 벤토 · 보드 계산 캐시

    private struct BentoKey: Equatable {
        var cards: [CardFingerprint]
        var revision: Int
        var layout: BoardLayout
        var summaries: [MemoSummary]
    }
    private struct CardFingerprint: Hashable {
        var id: MemoID
        var modified: Date
        var previewHash: Int
    }
    @ObservationIgnored private var bentoCache: (key: BentoKey, spans: [MemoID: BoardLayout.BentoSpan], order: [Int])?

    private func bentoEntry(for memos: [MemoSummary]) -> (spans: [MemoID: BoardLayout.BentoSpan], order: [Int]) {
        // 관찰 값(요약, 창 상태, 보드 배치)은 캐시 확인 전에 읽는다.
        let key = BentoKey(cards: memos.map { .init(id: $0.id, modified: $0.meta.modified, previewHash: $0.preview.hashValue) },
                           revision: windowStateRevision, layout: store.boardLayout, summaries: store.summaries)
        if let bentoCache, bentoCache.key == key { return (bentoCache.spans, bentoCache.order) }
        let spans = computeBentoSpans(for: memos)
        let rank: [BoardLayout.BentoSpan] = [.large, .wide, .tall, .small]
        let order = memos.indices.sorted { a, b in
            let x = rank.firstIndex(of: spans[memos[a].id] ?? .small)!
            let y = rank.firstIndex(of: spans[memos[b].id] ?? .small)!
            return x == y ? a < b : x < y
        }
        bentoCache = (key, spans, order)
        return (spans, order)
    }

    public func bentoSpans(for memos: [MemoSummary]) -> [MemoID: BoardLayout.BentoSpan] {
        bentoEntry(for: memos).spans
    }

    /// 벤토에서 큰 카드부터 놓는 차례로 정렬한 메모.
    func bentoOrdered(_ memos: [MemoSummary]) -> [MemoSummary] {
        if sortOrder.key == .manual { return memos }
        return bentoEntry(for: memos).order.map { memos[$0] }
    }

    private func computeBentoSpans(for memos: [MemoSummary]) -> [MemoID: BoardLayout.BentoSpan] {
        let index = linkIndex
        let recent = memos.sorted {
            $0.meta.modified == $1.meta.modified ? $0.id.rawValue < $1.id.rawValue : $0.meta.modified > $1.meta.modified
        }
        let bonuses = Dictionary(uniqueKeysWithValues: recent.prefix(3).enumerated().map { ($0.element.id, 3 - $0.offset) })
        func score(_ memo: MemoSummary) -> Int {
            (index.linkCount[memo.id] ?? 0) * 3 + (windowActions.isVisible(memo.id) ? 2 : 0) + (bonuses[memo.id] ?? 0)
        }
        let ranked = memos.sorted {
            score($0) == score($1) ? $0.id.rawValue < $1.id.rawValue : score($0) > score($1)
        }
        let ranks = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.id, $0.offset) })
        return Dictionary(uniqueKeysWithValues: memos.map { memo in
            let span: BoardLayout.BentoSpan
            if let manual = store.boardLayout.bentoSpan(for: memo.id) { span = manual }
            else if ranks[memo.id] == 0 && score(memo) > 0 { span = .large }
            else if (ranks[memo.id] ?? 3) < 3 { span = .wide }
            else if cardInfo(for: memo).total >= 3 { span = .tall }
            else { span = .small }
            return (memo.id, span)
        })
    }

    private struct PlacementKey: Equatable {
        var ids: [MemoID]
        var layout: BoardLayout
    }
    @ObservationIgnored private var placementCache: (key: PlacementKey, placements: [MemoID: BoardLayout.Placement])?
    @ObservationIgnored private var pipeCache: (key: PlacementKey, edges: [MemoEdge], pipes: [PipeGeometry], endpoints: [MemoID: [CGPoint]])?

    public func boardPlacements(for memos: [MemoSummary]) -> [MemoID: BoardLayout.Placement] {
        let key = PlacementKey(ids: memos.map(\.id), layout: store.boardLayout)
        if let placementCache, placementCache.key == key { return placementCache.placements }
        var result: [MemoID: BoardLayout.Placement] = [:]
        for memo in memos { result[memo.id] = store.boardLayout.placement(for: memo.id) }
        let startY = result.values.map { $0.y + 180 }.max() ?? 100
        var offset = 0
        for memo in memos where result[memo.id] == nil {
            result[memo.id] = .init(x: 40 + Double(offset % 4) * 260, y: startY + Double(offset / 4) * 180)
            offset += 1
        }
        placementCache = (key, result)
        return result
    }

    /// 드래그 중이 아닐 때 쓰는 파이프 모양. 메모 위치와 연결이 같으면 다시 계산하지 않는다.
    func boardPipes(for memos: [MemoSummary], edges: [MemoEdge]) -> [PipeGeometry] {
        let positions = boardPlacements(for: memos)
        let key = PlacementKey(ids: memos.map(\.id), layout: store.boardLayout)
        if let pipeCache, pipeCache.key == key, pipeCache.edges == edges { return pipeCache.pipes }
        let pipes = PipeGeometry.make(edges: edges, positions: positions)
        pipeCache = (key, edges, pipes, PipeGeometry.endpoints(of: pipes))
        return pipes
    }

    /// 메모마다 파이프가 닿는 점. boardPipes와 같은 키로 한 번만 계산한다.
    func boardEndpoints(for memos: [MemoSummary], edges: [MemoEdge]) -> [MemoID: [CGPoint]] {
        _ = boardPipes(for: memos, edges: edges)
        return pipeCache?.endpoints ?? [:]
    }

    /// 보드 재정렬: 파이프(흐름 · 관련)로 이어진 메모끼리 한 무리로 모은다.
    ///
    /// - 무리 안에서는 선 방향의 단계별 열을 만들고 이웃의 평균 자리에 맞춰 열 안 순서를 정한다.
    /// - 무리들은 큰 것부터 왼쪽 위에서 오른쪽으로 채우고, 폭이 넘치면 아래 줄로 내려간다(무리 사이 80pt).
    /// - 어디에도 이어지지 않은 메모는 맨 아래에 다섯 개씩 격자로 모은다.
    public func autoArrangedPlacements(for memos: [MemoSummary]) -> [MemoID: BoardLayout.Placement] {
        let columnStep = 280.0, rowStep = 200.0, cardWidth = 200.0, cardHeight = 120.0
        let groupGap = 80.0, maxRowWidth = 1400.0, origin = (x: 40.0, y: 100.0)
        let order = memos.map(\.id)
        let included = Set(order)
        let edges = linkIndex.edges.filter { included.contains($0.from) && included.contains($0.to) && $0.from != $0.to }

        // 이어진 무리 찾기 (합집합-찾기).
        var parent = Dictionary(uniqueKeysWithValues: order.map { ($0, $0) })
        func find(_ id: MemoID) -> MemoID {
            var root = id
            while let next = parent[root], next != root { root = next }
            var current = id
            while let next = parent[current], next != root { parent[current] = root; current = next }
            return root
        }
        for edge in edges {
            let a = find(edge.from), b = find(edge.to)
            if a != b { parent[b] = a }
        }
        var groups: [MemoID: [MemoID]] = [:]
        var groupOrder: [MemoID] = []
        for id in order {
            let root = find(id)
            if groups[root] == nil { groupOrder.append(root) }
            groups[root, default: []].append(id)
        }

        // 무리 하나를 자기 좌표(0,0 기준)로 배치한다.
        struct Block { var places: [MemoID: (Double, Double)]; var width: Double; var height: Double }
        func layout(_ members: [MemoID]) -> Block {
            let memberSet = Set(members)
            let connections = edges.filter { memberSet.contains($0.from) && memberSet.contains($0.to) }
            let ranks = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($0.element, $0.offset) })
            var levels = Dictionary(uniqueKeysWithValues: members.map { ($0, 0) })
            // 순환이 있어도 무리 크기만큼만 단계를 갱신한다.
            for _ in members {
                for edge in connections { levels[edge.to] = max(levels[edge.to]!, levels[edge.from]! + 1) }
            }
            let incoming = Set(connections.map(\.to))
            for id in members where !incoming.contains(id) {
                if let next = connections.filter({ $0.from == id }).map({ levels[$0.to]! }).min() {
                    levels[id] = max(0, next - 1)
                }
            }
            var layers = Dictionary(grouping: members, by: { levels[$0]! })
            let columns = layers.keys.sorted()
            var neighbors = Dictionary(uniqueKeysWithValues: members.map { ($0, [MemoID]()) })
            for edge in connections {
                neighbors[edge.from]!.append(edge.to)
                neighbors[edge.to]!.append(edge.from)
            }
            var slots: [MemoID: Double] = [:]
            for column in columns {
                let ids = layers[column]!
                for (index, id) in ids.enumerated() { slots[id] = Double(index) - Double(ids.count - 1) / 2 }
            }
            // 자바스크립트의 반올림처럼 음수의 정확한 중간값도 위쪽으로 맞춘다.
            func half(_ value: Double) -> Double { floor(value * 2 + 0.5) / 2 }
            for iteration in 0..<12 {
                for column in iteration % 2 == 0 ? columns : Array(columns.reversed()) {
                    var ids = layers[column]!
                    var wanted: [MemoID: Double] = [:]
                    for id in ids {
                        let others = neighbors[id]!.filter { levels[$0] != levels[id] }
                        wanted[id] = half(others.isEmpty ? slots[id]! : others.reduce(0) { $0 + slots[$1]! } / Double(others.count))
                    }
                    ids.sort { wanted[$0] == wanted[$1] ? ranks[$0]! < ranks[$1]! : wanted[$0]! < wanted[$1]! }
                    var values = ids.map { wanted[$0]! }
                    for i in values.indices.dropFirst() { values[i] = max(values[i], values[i - 1] + 1) }
                    let shift = half((ids.reduce(0) { $0 + wanted[$1]! } - values.reduce(0, +)) / Double(ids.count))
                    for (i, id) in ids.enumerated() { slots[id] = values[i] + shift }
                    layers[column] = ids
                }
            }
            let minimum = slots.values.min() ?? 0
            let places = Dictionary(uniqueKeysWithValues: members.map { ($0, (Double(levels[$0]!) * columnStep, (slots[$0]! - minimum) * rowStep)) })
            return Block(places: places,
                         width: (places.values.map { $0.0 }.max() ?? 0) + cardWidth,
                         height: (places.values.map { $0.1 }.max() ?? 0) + cardHeight)
        }

        let linked = groupOrder.compactMap { groups[$0] }.filter { $0.count > 1 }
            .sorted { $0.count == $1.count ? order.firstIndex(of: $0[0])! < order.firstIndex(of: $1[0])! : $0.count > $1.count }
        let singles = groupOrder.compactMap { groups[$0] }.filter { $0.count == 1 }.map { $0[0] }

        var result: [MemoID: BoardLayout.Placement] = [:]
        var x = origin.x, y = origin.y, shelfHeight = 0.0
        for members in linked {
            let block = layout(members)
            if x > origin.x, x + block.width > origin.x + maxRowWidth {
                x = origin.x
                y += shelfHeight + groupGap
                shelfHeight = 0
            }
            for (id, place) in block.places { result[id] = .init(x: x + place.0, y: y + place.1) }
            x += block.width + groupGap
            shelfHeight = max(shelfHeight, block.height)
        }
        let singlesTop = linked.isEmpty ? origin.y : y + shelfHeight + groupGap
        for (offset, id) in singles.enumerated() {
            result[id] = .init(x: origin.x + Double(offset % 5) * columnStep, y: singlesTop + Double(offset / 5) * rowStep)
        }
        return result
    }

    public func link(from: MemoID, to: MemoID, kind: MemoLinkKind, undoManager: UndoManager? = nil) {
        let previous = linkSnapshot(from, to)
        store.link(from: from, to: to, kind: kind)
        registerLinks(previous, name: "선 잇기", manager: undoManager)
    }
    public func unlink(_ a: MemoID, _ b: MemoID, undoManager: UndoManager? = nil) {
        let previous = linkSnapshot(a, b)
        store.unlink(a, b)
        registerLinks(previous, name: "선 끊기", manager: undoManager)
    }
    public func changeLink(_ edge: MemoEdge, kind: MemoLinkKind, undoManager: UndoManager? = nil) {
        guard edge.kind != kind else { return }
        let previous = linkSnapshot(edge.from, edge.to)
        store.link(from: edge.from, to: edge.to, kind: kind)
        registerLinks(previous, name: "선 모양 바꾸기", manager: undoManager)
    }
    public func renameLink(_ edge: MemoEdge, label: String, undoManager: UndoManager? = nil) {
        let value = MemoLink.normalizedLabel(label)
        guard value != edge.label else { return }
        let previous = linkSnapshot(edge.from, edge.to)
        store.updateMeta(id: edge.from) { meta in
            if let offset = meta.links.firstIndex(where: { $0.to == edge.to }) { meta.links[offset].label = value }
        }
        registerLinks(previous, name: "선 이름 바꾸기", manager: undoManager)
    }
    private func linkSnapshot(_ a: MemoID, _ b: MemoID) -> [MemoID: [MemoLink]] {
        Dictionary(uniqueKeysWithValues: store.summaries.filter { $0.id == a || $0.id == b }.map { ($0.id, $0.meta.links) })
    }
    private func registerLinks(_ links: [MemoID: [MemoLink]], name: String, manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { [weak manager] model in
            let inverse = Dictionary(uniqueKeysWithValues: model.store.summaries.filter { links[$0.id] != nil }.map { ($0.id, $0.meta.links) })
            for (id, values) in links { model.store.updateMeta(id: id) { $0.links = values } }
            model.registerLinks(inverse, name: name, manager: manager)
        }
        manager.setActionName(name)
    }
    private func registerPlacementUndo(_ positions: [String: BoardLayout.Placement], name: String, manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { [weak manager] model in
            let inverse = model.store.boardLayout.placements
            model.store.replaceBoardPlacements(positions)
            model.registerPlacementUndo(inverse, name: name, manager: manager)
        }
        manager.setActionName(name)
    }
    public func openFlow(_ flow: MemoFlow) { open(flow.memoIDs) }
    public func arrangeFlow(_ flow: MemoFlow) {
        windowActions.arrangeInOrder(flow.memoIDs)
        noteWindowStateChanged()
    }
    public func setBentoSpan(_ span: BoardLayout.BentoSpan?, for id: MemoID) { store.setBentoSpan(span, for: id) }
    public func moveCard(_ id: MemoID, to placement: BoardLayout.Placement) { moveCards([id: placement]) }
    public func moveCards(_ placements: [MemoID: BoardLayout.Placement], freezing memos: [MemoSummary] = [], undoManager: UndoManager? = nil) {
        guard !placements.isEmpty else { return }
        let previous = store.boardLayout.placements
        // 옮기기 전 보이던 미저장 자리도 같은 저장 작업에 포함한다.
        let frozen = boardPlacements(for: memos).filter { store.boardLayout.placements[$0.key.rawValue] == nil }
        store.setBoardPlacements(frozen.merging(placements) { _, moved in moved }.mapValues {
            .init(x: ($0.x / 20).rounded() * 20, y: ($0.y / 20).rounded() * 20)
        })
        registerPlacementUndo(previous, name: "카드 옮기기", manager: undoManager)
    }
    public func autoArrange(_ memos: [MemoSummary], undoManager: UndoManager? = nil) {
        let previous = store.boardLayout.placements
        store.setBoardPlacements(autoArrangedPlacements(for: memos))
        registerPlacementUndo(previous, name: "재정렬", manager: undoManager)
    }
    public func pasteMemo(_ body: String, at placement: BoardLayout.Placement, undoManager: UndoManager? = nil) {
        let group: String?
        if case .group(let name) = scope { group = name } else { group = nil }
        let meta = store.createMemo(group: group)
        store.saveBody(id: meta.id, body: body)
        moveCard(meta.id, to: placement)
        selection = [meta.id]
        registerPasteUndo(meta.id, trash: true, manager: undoManager)
    }
    private func registerPasteUndo(_ id: MemoID, trash: Bool, manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { [weak manager] model in
            if trash { model.store.moveToTrash(id: id); model.selection.remove(id) }
            else { model.store.restoreFromTrash(id: id); model.selection = [id] }
            model.registerPasteUndo(id, trash: !trash, manager: manager)
        }
        manager.setActionName("메모 붙여넣기")
    }

    public static func checklist(_ memo: MemoSummary) -> [(text: String, checked: Bool)] {
        memo.preview.components(separatedBy: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("- [ ] ") || text.hasPrefix("- [x] ") || text.hasPrefix("- [X] ") else { return nil }
            return (String(text.dropFirst(6)), !text.hasPrefix("- [ ] "))
        }
    }

}
