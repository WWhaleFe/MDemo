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

    private struct VisibleKey: Equatable {
        var scope: Scope
        var query: String
        var sortOrder: MemoSortOrder
        var summaries: [MemoSummary]
        var trashed: [MemoSummary]
        var revision: Int
    }
    @ObservationIgnored private var visibleCache: (key: VisibleKey, memos: [MemoSummary])?

    /// 지금 화면에 보여 줄 메모들. 한 번 그릴 때 여러 번 불리므로 같은 입력이면 이전 결과를 돌려준다.
    public var visibleMemos: [MemoSummary] {
        // 캐시를 쓰더라도 관찰 값은 모두 읽어야 화면이 다시 그려진다.
        let key = VisibleKey(scope: scope, query: query, sortOrder: sortOrder, summaries: store.summaries,
                             trashed: store.trashed, revision: windowStateRevision)
        if let visibleCache, visibleCache.key == key { return visibleCache.memos }
        let memos = computeVisibleMemos()
        visibleCache = (key, memos)
        return memos
    }

    private func computeVisibleMemos() -> [MemoSummary] {
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
        case .flow(let id):
            guard let flow = linkIndex.flows.first(where: { $0.id == id }) else { return [] }
            let byID = Dictionary(uniqueKeysWithValues: store.summaries.map { ($0.id, $0) })
            return flow.memoIDs.compactMap { byID[$0] }.filter { MemoSearch.matches($0, query: query) }
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
        bentoEntry(for: memos).order.map { memos[$0] }
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

    public func autoArrangedPlacements(for memos: [MemoSummary]) -> [MemoID: BoardLayout.Placement] {
        let included = Set(memos.map(\.id))
        var result: [MemoID: BoardLayout.Placement] = [:]
        var row = 0
        for flow in linkIndex.flows {
            let ids = flow.memoIDs.filter { included.contains($0) }
            guard !ids.isEmpty else { continue }
            for (column, id) in ids.enumerated() {
                result[id] = .init(x: 40 + Double(column) * 280, y: 100 + Double(row) * 180)
            }
            row += 1
        }
        for (offset, memo) in memos.filter({ result[$0.id] == nil }).enumerated() {
            result[memo.id] = .init(x: 40 + Double(offset % 4) * 260, y: 100 + Double(row + offset / 4) * 180)
        }
        return result
    }

    public func link(from: MemoID, to: MemoID, kind: MemoLinkKind) { store.link(from: from, to: to, kind: kind) }
    public func unlink(_ a: MemoID, _ b: MemoID) { store.unlink(a, b) }
    public func openFlow(_ flow: MemoFlow) { open(flow.memoIDs) }
    public func arrangeFlow(_ flow: MemoFlow) {
        windowActions.arrangeInOrder(flow.memoIDs)
        noteWindowStateChanged()
    }
    public func setBentoSpan(_ span: BoardLayout.BentoSpan?, for id: MemoID) { store.setBentoSpan(span, for: id) }
    public func moveCard(_ id: MemoID, to placement: BoardLayout.Placement) { moveCards([id: placement]) }
    public func moveCards(_ placements: [MemoID: BoardLayout.Placement]) {
        store.setBoardPlacements(placements.mapValues {
            .init(x: ($0.x / 20).rounded() * 20, y: ($0.y / 20).rounded() * 20)
        })
    }
    public func autoArrange(_ memos: [MemoSummary]) { store.setBoardPlacements(autoArrangedPlacements(for: memos)) }
    public func pasteMemo(_ body: String, at placement: BoardLayout.Placement) {
        let group: String?
        if case .group(let name) = scope { group = name } else { group = nil }
        let meta = store.createMemo(group: group)
        store.saveBody(id: meta.id, body: body)
        moveCard(meta.id, to: placement)
        selection = [meta.id]
    }

    public static func checklist(_ memo: MemoSummary) -> [(text: String, checked: Bool)] {
        memo.preview.components(separatedBy: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("- [ ] ") || text.hasPrefix("- [x] ") || text.hasPrefix("- [X] ") else { return nil }
            return (String(text.dropFirst(6)), !text.hasPrefix("- [ ] "))
        }
    }

}
