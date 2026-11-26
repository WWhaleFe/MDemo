@testable import Features
import Foundation
import SwiftUI
import ImageIO
import Services
import UniformTypeIdentifiers
import MemoCore
import TestKit

// 리스트 창이 "무엇을 보여 줄지" 정하는 규칙을 확인한다.
// 화면 없이 시험할 수 있게 계산을 모델로 빼 둔 덕에 여기서 다 잡힌다.

let runner = TestRunner("Features")

/// 테스트가 이 맥의 실제 키체인을 건드리지 않게, 저장소는 모두 메모리 키체인을 쓴다.
final class TestMemoKeychain: MemoKeychain, @unchecked Sendable {
    private let mutex = NSLock()
    private var failures: [MemoID: Int] = [:]
    func readFailures(id: MemoID) throws -> Int { mutex.lock(); defer { mutex.unlock() }; return failures[id] ?? 0 }
    func writeFailures(_ count: Int, id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; failures[id] = count }
    private var values: [MemoID: Data] = [:]
    func read(id: MemoID) throws -> Data? { mutex.lock(); defer { mutex.unlock() }; return values[id] }
    func write(_ value: Data, id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; values[id] = value }
    func delete(id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; values[id] = nil; failures[id] = nil }
}
let testKeychain = TestMemoKeychain()

@MainActor
func makeModel() throws -> (MemoListModel, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MDemoFeatureTests-\(UUID().uuidString)", isDirectory: true)
    let repository = try FileMemoRepository(rootDirectory: root, keychain: testKeychain)
    let model = MemoListModel(store: MemoStore(repository: repository, keychain: testKeychain))
    model.searchDebounce = 0
    return (model, root)
}

/// 창 계층을 흉내 낸다. 어떤 메모가 화면에 떠 있는지만 기억하면 목록 규칙은 다 시험할 수 있다.
@MainActor
final class FakeWindows {
    var onScreen: Set<MemoID> = []
    private(set) var arrangeCalls: [Bool] = []

    var actions: MemoWindowActions {
        MemoWindowActions(
            isVisible: { [self] id in onScreen.contains(id) },
            open: { [self] ids in onScreen.formUnion(ids) },
            hide: { [self] ids in onScreen.subtract(ids) },
            arrange: { [self] byGroup in arrangeCalls.append(byGroup) }
        )
    }
}

@MainActor
func makeModelWithWindows() throws -> (MemoListModel, FakeWindows, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MDemoFeatureTests-\(UUID().uuidString)", isDirectory: true)
    let repository = try FileMemoRepository(rootDirectory: root, keychain: testKeychain)
    let windows = FakeWindows()
    let model = MemoListModel(store: MemoStore(repository: repository, keychain: testKeychain), windowActions: windows.actions)
    model.searchDebounce = 0
    return (model, windows, root)
}

runner.test("전체 보기에는 모든 메모가 나온다 (LST-01)") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        model.store.createMemo(group: "업무")
        model.store.createMemo()
        t.expectEqual(model.visibleMemos.count, 2)
    }
}

runner.test("그룹을 고르면 그 그룹만 보인다 (LST-02)") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        model.store.createGroup(named: "업무")
        let work = model.store.createMemo(group: "업무")
        model.store.createMemo(group: "개인")

        model.prepare(for: .group("업무"))
        t.expectEqual(model.visibleMemos.count, 1)
        t.expectEqual(model.visibleMemos.first?.id, work.id)
    }
}

runner.test("그룹 없는 메모만 따로 볼 수 있다 (LST-03)") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let loose = model.store.createMemo()
        model.store.createMemo(group: "업무")

        model.prepare(for: .ungrouped)
        t.expectEqual(model.visibleMemos.count, 1)
        t.expectEqual(model.visibleMemos.first?.id, loose.id)
    }
}

runner.test("검색과 정렬이 함께 적용된다 (SRC-01, SRC-03)") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = model.store.createMemo()
        model.store.saveBody(id: first.id, body: "# 가나다 회의")
        let second = model.store.createMemo()
        model.store.saveBody(id: second.id, body: "# 하하하 회의")
        let other = model.store.createMemo()
        model.store.saveBody(id: other.id, body: "# 관계없는 메모")

        model.query = "회의"
        t.expectEqual(model.visibleMemos.count, 2, "검색이 적용되지 않았다")

        model.sortOrder = MemoSortOrder(key: .title, ascending: true)
        t.expectEqual(model.visibleMemos.first?.id, first.id, "제목 오름차순이 적용되지 않았다")

        model.sortOrder = MemoSortOrder(key: .title, ascending: false)
        t.expectEqual(model.visibleMemos.first?.id, second.id, "내림차순이 적용되지 않았다")
    }
}

runner.test("휴지통 보기로 바꾸면 버린 메모가 나온다 (TRS-01, TRS-02)") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = model.store.createMemo()
        model.store.saveBody(id: meta.id, body: "# 버릴 메모")
        model.store.moveToTrash(id: meta.id)

        t.expectEqual(model.visibleMemos.count, 0, "목록에 남아 있으면 안 된다")

        model.prepare(for: .trash)
        t.expect(model.isShowingTrash)
        t.expectEqual(model.visibleMemos.count, 1, "휴지통에 보이지 않는다")

        model.selection = [meta.id]
        model.restoreSelection()
        model.prepare(for: .all)
        t.expectEqual(model.visibleMemos.count, 1, "복원되지 않았다")
    }
}

runner.test("여러 개를 골라 한 번에 옮기고 버린다 (LST-05)") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        model.store.createGroup(named: "보관")
        let first = model.store.createMemo()
        let second = model.store.createMemo()

        model.selection = [first.id, second.id]
        model.assignSelection(to: "보관")
        t.expectEqual(model.store.memoCount(inGroup: "보관"), 2, "일괄 이동이 안 됐다")

        model.selection = [first.id, second.id]
        model.moveSelectionToTrash()
        t.expectEqual(model.visibleMemos.count, 0, "일괄 삭제가 안 됐다")
        t.expectEqual(model.selection.count, 0, "선택이 남아 있다")
    }
}

runner.test("왼쪽 목록에 그룹과 개수가 나온다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        model.store.createGroup(named: "업무")
        model.store.createMemo(group: "업무")
        model.store.createMemo()

        let items = model.sidebarItems
        t.expect(items.contains { $0.scope == .all && $0.count == 2 }, "전체 개수가 맞지 않다")
        t.expect(items.contains { $0.scope == .group("업무") && $0.count == 1 }, "그룹 개수가 맞지 않다")
        t.expect(items.contains { $0.scope == .trash }, "휴지통 항목이 없다")
    }
}

runner.test("보이는 메모와 숨겨진 메모가 갈라진다 (LST-09)") { t in
    try MainActor.assumeIsolated {
        let (model, windows, root) = try makeModelWithWindows()
        defer { try? FileManager.default.removeItem(at: root) }

        let shown = model.store.createMemo().id
        model.store.createMemo()
        model.store.createMemo()
        windows.onScreen = [shown]
        model.noteWindowStateChanged()

        model.prepare(for: .visible)
        t.expectEqual(model.visibleMemos.map(\.id), [shown])

        model.prepare(for: .hidden)
        t.expectEqual(model.visibleMemos.count, 2, "화면에 없는 메모 둘이 나와야 한다")

        let counts = Dictionary(uniqueKeysWithValues: model.viewSidebarItems.map { ($0.scope, $0.count) })
        t.expectEqual(counts[.all], 3)
        t.expectEqual(counts[.visible], 1)
        t.expectEqual(counts[.hidden], 2)
    }
}

runner.test("모두 띄우기·모두 숨기기·선택 띄우기가 창 상태를 바꾼다 (LST-10)") { t in
    try MainActor.assumeIsolated {
        let (model, windows, root) = try makeModelWithWindows()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = model.store.createMemo().id
        let second = model.store.createMemo().id

        model.showAll()
        t.expectEqual(windows.onScreen.count, 2, "모두 띄우기가 두 개를 올리지 않았다")

        model.hideAll()
        t.expect(windows.onScreen.isEmpty, "모두 숨기기가 남긴 창이 있다")

        model.selection = [second]
        model.showSelection()
        t.expectEqual(windows.onScreen, [second], "고른 것만 떠야 한다")

        // 한 줄의 눈 아이콘은 그 메모만 뒤집는다.
        model.toggleVisibility(of: first)
        t.expectEqual(windows.onScreen, [first, second])
        model.toggleVisibility(of: second)
        t.expectEqual(windows.onScreen, [first])
    }
}

runner.test("숨겨도 메모는 남는다 (LST-10)") { t in
    try MainActor.assumeIsolated {
        let (model, _, root) = try makeModelWithWindows()
        defer { try? FileManager.default.removeItem(at: root) }

        model.store.createMemo()
        model.store.createMemo()
        model.showAll()
        model.hideAll()

        model.prepare(for: .all)
        t.expectEqual(model.visibleMemos.count, 2, "숨기기가 메모를 지웠다")
        t.expect(model.store.trashed.isEmpty, "숨기기가 휴지통으로 보냈다")
    }
}

runner.test("창 나열과 그룹 나열은 서로 다른 요청을 보낸다 (LST-06, LST-11)") { t in
    try MainActor.assumeIsolated {
        let (model, windows, root) = try makeModelWithWindows()
        defer { try? FileManager.default.removeItem(at: root) }

        model.arrangeWindows(byGroup: false)
        model.arrangeWindows(byGroup: true)
        t.expectEqual(windows.arrangeCalls, [false, true])
    }
}

runner.test("한꺼번에 띄우기 전에 확인을 받을지 정한다 (NFR-02)") { t in
    try MainActor.assumeIsolated {
        let (model, _, root) = try makeModelWithWindows()
        defer { try? FileManager.default.removeItem(at: root) }

        for _ in 0..<MemoListModel.bulkOpenWarningThreshold {
            model.store.createMemo()
        }
        t.expect(!model.needsBulkOpenConfirmation, "한계선까지는 바로 띄워야 한다")

        model.store.createMemo()
        t.expect(model.needsBulkOpenConfirmation, "한계선을 넘으면 확인을 받아야 한다")
    }
}

runner.test("여러 개를 골라 복원하고 영구 삭제한다 (LST-05, TRS-02)") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let ids = (0..<3).map { _ in model.store.createMemo().id }
        model.selection = Set(ids)
        model.moveSelectionToTrash()

        model.prepare(for: .trash)
        t.expectEqual(model.visibleMemos.count, 3)
        model.selection = [ids[0], ids[1]]
        model.restoreSelection()
        t.expectEqual(model.visibleMemos.count, 1, "고른 것만 복원돼야 한다")

        model.selectAllVisible()
        model.deleteSelectionPermanently()
        t.expectEqual(model.visibleMemos.count, 0, "영구 삭제가 안 됐다")
        model.prepare(for: .all)
        t.expectEqual(model.visibleMemos.count, 2)
    }
}

runner.test("우클릭한 줄이 선택에 들어 있으면 선택 전체가 대상이다 (LST-05)") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<3).map { _ in model.store.createMemo().id }

        var opened: [MemoID] = []
        model.windowActions = MemoWindowActions(open: { opened += $0 })
        model.open(model.targets(for: [ids[0], ids[2]]))
        t.expectEqual(Set(opened), [ids[0], ids[2]], "고른 메모만 열려야 한다")
    }
}

runner.test("흐름 범위는 연결 순서를 지키고 검색과 사라진 흐름을 처리한다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<3).map { _ in model.store.createMemo().id }
        for (i, id) in ids.enumerated() { model.store.saveBody(id: id, body: "단계 \(i)") }
        model.link(from: ids[2], to: ids[0], kind: .flow)
        model.link(from: ids[0], to: ids[1], kind: .flow)
        model.prepare(for: .flow(ids[2]))
        model.sortOrder = .init(key: .title, ascending: true)
        t.expectEqual(model.visibleMemos.map(\.id), [ids[2], ids[0], ids[1]])
        t.expectEqual(model.scopeTitle, "단계 2")
        let item = model.flowSidebarItems.first
        t.expectEqual(item?.scope, .flow(ids[2]))
        t.expectEqual(item?.title, "단계 2")
        t.expectEqual(item?.count, 3)
        t.expectEqual(model.flowContext(of: ids[0])?.index, 1)
        model.query = "단계 0"
        t.expectEqual(model.visibleMemos.map(\.id), [ids[0]])
        model.unlink(ids[2], ids[0])
        t.expectEqual(model.visibleMemos.count, 0)
        t.expectEqual(model.linkIndex.linkCount[ids[2]], nil)
    }
}

runner.test("벤토는 연결 점수와 최근 수정 보너스를 쓰고 수동 크기를 우선한다") { t in
    try MainActor.assumeIsolated {
        let (model, windows, root) = try makeModelWithWindows()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<6).map { _ in model.store.createMemo().id }
        model.link(from: ids[0], to: ids[1], kind: .related)
        model.link(from: ids[0], to: ids[2], kind: .related)
        windows.onScreen = [ids[0]]
        var memos = model.store.summaries
        let date = Date(timeIntervalSince1970: 1_000_000)
        for i in memos.indices {
            memos[i].meta.modified = date.addingTimeInterval(Double(i))
            if memos[i].id == ids[3] { memos[i].preview = "할 일\n- [ ] 가\n- [x] 나\n- [ ] 다" }
        }
        // 체크박스 카드는 최근 수정 상위 세 개에서 제외한다.
        let taskIndex = memos.firstIndex { $0.id == ids[3] }!
        memos[taskIndex].meta.modified = .distantPast
        let spans = model.bentoSpans(for: memos)
        t.expectEqual(spans[ids[0]], .large)
        t.expectEqual(spans[ids[3]], .tall)
        t.expectEqual(spans.values.filter { $0 == .wide }.count, 2)
        model.setBentoSpan(.small, for: ids[0])
        t.expectEqual(model.bentoSpans(for: memos)[ids[0]], .small)
        model.setBentoSpan(nil, for: ids[0])
        t.expectEqual(model.bentoSpans(for: memos)[ids[0]], .large)
    }
}

runner.test("연결 없는 벤토도 최근 수정 순위와 표시 상태로 점수를 매긴다") { t in
    try MainActor.assumeIsolated {
        let (model, windows, root) = try makeModelWithWindows()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<4).map { _ in model.store.createMemo().id }
        var memos = ids.compactMap { id in model.store.summaries.first { $0.id == id } }
        for i in memos.indices { memos[i].meta.modified = Date(timeIntervalSince1970: Double(100 - i)) }
        t.expectEqual(model.bentoSpans(for: memos)[ids[0]], .large)
        windows.onScreen = [ids[1]]
        model.noteWindowStateChanged()
        t.expectEqual(model.bentoSpans(for: memos)[ids[1]], .large)
        t.expectEqual(model.bentoSpans(for: [])[ids[0]], nil)
    }
}

runner.test("보드 기본 배치는 저장하지 않고 네 열로 채우며 저장값 아래에 놓는다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<6 { model.store.createMemo() }
        let memos = model.visibleMemos
        let placements = model.boardPlacements(for: memos)
        t.expectEqual(placements[memos[0].id], .init(x: 40, y: 100))
        t.expectEqual(placements[memos[3].id], .init(x: 820, y: 100))
        t.expectEqual(placements[memos[4].id], .init(x: 40, y: 280))
        t.expect(model.store.boardLayout.placements.isEmpty)
        model.store.setBoardPlacement(.init(x: -120, y: 500), for: memos[0].id)
        let saved = model.boardPlacements(for: memos)
        t.expectEqual(saved[memos[0].id], .init(x: -120, y: 500))
        t.expectEqual(saved[memos[1].id], .init(x: 40, y: 680))
        t.expectEqual(model.boardPlacements(for: []).count, 0)
        model.moveCard(memos[1].id, to: .init(x: 53, y: 109))
        t.expectEqual(model.store.boardLayout.placement(for: memos[1].id), .init(x: 60, y: 100))
    }
}

runner.test("재정렬은 이어진 메모끼리 한 무리로 모으고 방향에 따라 열을 나누고 외톨이는 맨 아래에 둔다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<9).map { _ in model.store.createMemo().id }
        model.link(from: ids[0], to: ids[1], kind: .flow)
        model.link(from: ids[1], to: ids[2], kind: .flow)
        model.link(from: ids[2], to: ids[7], kind: .related)
        model.link(from: ids[3], to: ids[4], kind: .flow)
        model.link(from: ids[5], to: ids[6], kind: .related)
        let memos = ids.compactMap { id in model.store.summaries.first { $0.id == id } }
        let positions = model.autoArrangedPlacements(for: memos)
        // 가장 큰 무리는 방향에 따라 네 열을 차지한다.
        t.expectEqual(positions[ids[0]], .init(x: 40, y: 100))
        for i in 1...2 { t.expectEqual(positions[ids[i]]!.x - positions[ids[i - 1]]!.x, 280) }
        t.expectEqual(positions[ids[7]]!.x - positions[ids[2]]!.x, 280)
        // 두 작은 무리는 다음 선반에서 옆으로 이어 붙는다.
        t.expectEqual(positions[ids[3]], .init(x: 40, y: 300))
        t.expectEqual(positions[ids[4]], .init(x: 320, y: 300))
        t.expectEqual(positions[ids[5]], .init(x: 600, y: 300))
        t.expectEqual(positions[ids[6]], .init(x: 880, y: 300))
        for i in ids.indices {
            for j in ids.indices where j > i {
                let a = positions[ids[i]]!, b = positions[ids[j]]!
                t.expect(!CGRect(x: a.x, y: a.y, width: 200, height: 120)
                    .intersects(CGRect(x: b.x, y: b.y, width: 200, height: 120)))
            }
        }
        t.expectEqual(positions, model.autoArrangedPlacements(for: memos))
        // 외톨이 8은 모든 무리보다 아래.
        let lowest = [0, 1, 2, 3, 4, 5, 6, 7].compactMap { positions[ids[$0]]?.y }.max() ?? 0
        t.expect((positions[ids[8]]?.y ?? 0) > lowest)
        t.expectEqual(positions[ids[8]]?.x, 40)
        var ordered: [MemoID] = []
        model.windowActions.arrangeInOrder = { ordered = $0 }
        let revision = model.windowStateRevision
        let flow = model.linkIndex.flows.first { $0.memoIDs.first == ids[0] }!
        model.arrangeFlow(flow)
        t.expectEqual(ordered, [ids[0], ids[1], ids[2]])
        t.expectEqual(model.windowStateRevision, revision + 1)
    }
}

runner.test("보기는 목록 그리드 벤토 보드 네 가지다") { t in
    t.expectEqual(MemoListModel.ViewMode.allCases.map(\.rawValue), ["list", "grid", "bento", "board"])
    t.expectEqual(MemoListModel.ViewMode.allCases.map(\.label), ["목록", "그리드", "벤토", "보드"])
}

runner.test("보드 붙여넣기는 본문과 그룹을 보존하고 위치와 선택을 기록한다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.store.createGroup(named: "작업")
        model.prepare(for: .group("작업"))
        model.pasteMemo("붙인 제목\n붙인 본문", at: .init(x: 53, y: 91))
        let memo = model.visibleMemos.first!
        t.expectEqual(memo.title, "붙인 제목")
        t.expectEqual(model.store.loadDocument(id: memo.id)?.body, "붙인 제목\n붙인 본문")
        t.expectEqual(memo.meta.group, "작업")
        t.expectEqual(model.selection, [memo.id])
        t.expectEqual(model.store.boardLayout.placement(for: memo.id), .init(x: 60, y: 100))
        let restarted = MemoStore(repository: try FileMemoRepository(rootDirectory: root, keychain: testKeychain))
        t.expectEqual(restarted.boardLayout.placement(for: memo.id), .init(x: 60, y: 100))
    }
}

runner.test("미리보기는 마크다운 기호를 지우고 줄 표시 방식을 나눈다") { t in
    let source = "제목\n- [ ] **준비**\n- [x] __완료__\n* 항목\n+ 추가\n12. 순서\n> 인용\n### 소제목\n```swift\n`코드` ~~취소~~ *기울임*\n```"
    let lines = ["준비", "완료", "항목", "추가", "순서", "인용", "소제목", "코드 취소 기울임"]
    t.expectEqual(cleanedMemoPreview(source), lines.joined(separator: "\n"))
    t.expectEqual(cleanedMemoPreview(source, singleLine: true), lines.joined(separator: " · "))
}

runner.test("카드 정보 캐시는 수정 시각이나 본문이 바뀔 때만 다시 계산한다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = model.store.createMemo(group: nil)
        var memo = MemoSummary(meta: meta, preview: "제목\n- [ ] 가\n- [x] **나**")
        let first = model.cardInfo(for: memo)
        t.expectEqual(first.preview, "가\n나")
        t.expectEqual(first.total, 2)
        t.expectEqual(first.done, 1)
        t.expectEqual(first.singleLinePreview, "가 · 나")
        _ = model.cardInfo(for: memo)
        t.expectEqual(model.cardInfoComputations, 1)
        memo.meta.modified = memo.meta.modified.addingTimeInterval(10)
        memo.preview = "제목\n- [x] 가\n- [x] 나\n- [ ] 다"
        let second = model.cardInfo(for: memo)
        t.expectEqual(model.cardInfoComputations, 2)
        t.expectEqual(second.total, 3)
        t.expectEqual(second.done, 2)
    }
}

runner.test("벤토 배치는 열 수와 칸 크기를 지키고 띠는 모든 카드를 한 번씩 담는다") { t in
    let spans: [BoardLayout.BentoSpan] = [.large, .small, .small, .wide, .tall, .small, .small, .large, .small, .tall, .wide, .small, .small, .small, .small]
    for width in [300.0, 500, 700, 900] {
        let (cells, columns) = BentoGrid.bentoCells(spans: spans, width: width)
        t.expectEqual(columns, Int(max(2, min(4, width / 220))))
        t.expectEqual(cells.count, spans.count)
        t.expect(cells.allSatisfy { $0.minX >= 0 && $0.maxX <= width + 0.001 }, "칸이 폭을 넘음 \(width)")
        for (i, a) in cells.enumerated() { for b in cells[(i + 1)...] { t.expect(!a.intersects(b), "칸이 겹침 \(width)") } }
        t.expectEqual(cells[0].height, 280)
        for rowsPerBand in [1, 2, 3] {
            let bands = BentoGrid.bands(cells: cells, rowsPerBand: rowsPerBand)
            t.expectEqual(bands.flatMap(\.cardIndices).sorted(), Array(0..<spans.count))
            for band in bands {
                for i in band.cardIndices {
                    t.expect(cells[i].minY >= band.minY - 0.001 && cells[i].maxY <= band.minY + band.height + 0.001, "카드가 띠를 넘음")
                }
            }
            t.expectEqual(bands.map(\.rowRange.lowerBound), [0] + bands.dropLast().map(\.rowRange.upperBound))
        }
    }
    t.expectEqual(BentoGrid.bands(cells: []).count, 0)
}

runner.test("보드 파이프 끝점은 메모마다 시작 메모는 첫 점, 끝 메모는 마지막 점") { t in
    let a = MemoID(rawValue: "a"), b = MemoID(rawValue: "b")
    let pipe = PipeGeometry(edge: MemoEdge(from: a, to: b, kind: .flow),
                            a: CGRect(x: 0, y: 0, width: 200, height: 120), b: CGRect(x: 400, y: 0, width: 200, height: 120))
    let points = PipeGeometry.endpoints(of: [pipe])
    t.expectEqual(points[a], [pipe.points.first!])
    t.expectEqual(points[b], [pipe.points.last!])
}

runner.test("찾는 범위와 그룹이 모든 범위에서 같은 규칙으로 적용된다") { t in
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = model.store.createMemo(group: "업무")
    model.store.saveBody(id: work.id, body: "업무 메모\n본문낱말")
    let free = model.store.createMemo()
    model.store.saveBody(id: free.id, body: "자유 메모\n본문낱말")

    model.query = "본문낱말"
    t.expectEqual(model.visibleMemos.count, 2)
    model.searchTarget = .title
    t.expectEqual(model.visibleMemos.count, 0, "제목 찾기에 본문이 걸렸다")
    model.searchTarget = .body
    model.searchGroup = .named("업무")
    t.expectEqual(model.visibleMemos.map(\.id), [work.id])
    model.searchGroup = .ungrouped
    t.expectEqual(model.visibleMemos.map(\.id), [free.id])
    model.prepare(for: .ungrouped)
    t.expectEqual(model.visibleMemos.map(\.id), [free.id])
    model.resetSearchOptions()
    t.expect(!model.hasCustomSearchOptions, "기본값으로 돌아오지 않았다")
    UserDefaults.standard.removeObject(forKey: "memoList.searchTarget")
}

runner.test("미리보기에서 이미지 줄은 원문 대신 [이미지]로 보인다") { t in
    let source = "제목\n![영수증](attachments/a1b2c3d4.png =260)\n본문\n![잘린](attachments/ab"
    t.expectEqual(cleanedMemoPreview(source), "[이미지]\n본문\n[이미지]")
    t.expectEqual(cleanedMemoPreview(source, singleLine: true), "[이미지] · 본문 · [이미지]")
    // 이미지로 시작하는 메모는 이미지 줄이 아니라 첫 글 줄이 제목이다.
    t.expectEqual(cleanedMemoPreview("![](attachments/x.png)\n진짜 제목\n내용"), "[이미지]\n내용")
    // 이미지만 있어도 깨지지 않는다.
    t.expectEqual(cleanedMemoPreview("![](attachments/x.png)"), "[이미지]")
    // 느낌표로 시작하는 보통 글은 이미지가 아니다.
    t.expectEqual(cleanedMemoPreview("제목\n![중요] 메모"), "![중요] 메모")
}

runner.test("이미지 줄은 체크리스트 진행 계산에 영향이 없다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = model.store.createMemo()
        model.store.saveBody(id: meta.id, body: "할 일\n![](attachments/x.png)\n- [x] 하나\n![](attachments/y.png)\n- [ ] 둘")
        model.refresh()
        guard let memo = model.visibleMemos.first(where: { $0.id == meta.id }) else { t.expect(false, "메모 없음"); return }
        let info = model.cardInfo(for: memo)
        t.expectEqual(info.tasks.map(\.checked), [true, false])
        t.expectEqual(info.tasks.map(\.text), ["하나", "둘"])
        t.expect(!info.preview.contains("!["), "미리보기에 이미지 원문이 남았다: \(info.preview)")
        t.expectEqual(info.singleLinePreview, "[이미지] · 하나 · [이미지] · 둘")
    }
}

@MainActor
func writeTestPNG(to url: URL) throws {
    let context = CGContext(
        data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

runner.test("목록에서 받은 사진은 첨부 폴더에 저장되고 본문 맨 위 · 맨 아래에 순서대로 들어간다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let first = downloads.appendingPathComponent("사진 하나.png")
        let second = downloads.appendingPathComponent("둘.png")
        try writeTestPNG(to: first)
        try writeTestPNG(to: second)

        let top = model.store.createMemo()
        model.store.saveBody(id: top.id, body: "# 제목\n본문")
        var editCalls = 0
        let actions = MemoWindowActions(withExternalBodyEdit: { _, edit in editCalls += 1; edit() })
        let topSession = ListAirDropSession(
            memoID: top.id, title: "제목", position: .top, store: model.store, windowActions: actions,
            receiver: AirDropReceiver(directory: downloads)
        )
        topSession.handleReceived(first)
        topSession.handleReceived(second)
        let topBody = model.store.loadDocument(id: top.id)?.body ?? ""
        let topLines = topBody.components(separatedBy: "\n")
        t.expectEqual(topLines.first, "# 제목")
        t.expect(topLines[1].hasPrefix("![사진 하나](attachments/") && topLines[2].hasPrefix("![둘](attachments/"), "순서가 다르다: \(topBody)")
        t.expectEqual(topLines.last, "본문")
        t.expectEqual(editCalls, 2, "창 쪽 편집 경로를 거쳐야 한다")

        let bottom = model.store.createMemo()
        model.store.saveBody(id: bottom.id, body: "글")
        let bottomSession = ListAirDropSession(
            memoID: bottom.id, title: "글", position: .bottom, store: model.store, windowActions: actions,
            receiver: AirDropReceiver(directory: downloads)
        )
        bottomSession.handleReceived(first)
        let bottomLines = (model.store.loadDocument(id: bottom.id)?.body ?? "").components(separatedBy: "\n")
        t.expectEqual(bottomLines.first, "글")
        t.expect(bottomLines.last?.hasPrefix("![사진 하나](attachments/") == true)

        // 첨부 파일이 그 메모의 폴더에 저장되고, 다운로드 폴더 원본은 그대로다.
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: model.store.attachmentsDirectory(for: top.id).path)) ?? []
        t.expectEqual(saved.count, 2)
        t.expect(FileManager.default.fileExists(atPath: first.path), "원본이 지워졌다")
        // 읽을 수 없는 파일은 건너뛰고 본문을 건드리지 않는다.
        let broken = downloads.appendingPathComponent("깨짐.png")
        try Data([1, 2, 3]).write(to: broken)
        let before = model.store.loadDocument(id: bottom.id)?.body
        bottomSession.handleReceived(broken)
        t.expectEqual(model.store.loadDocument(id: bottom.id)?.body, before)
    }
}


final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

runner.test("복제 메뉴는 잠금과 휴지통에서 차단하고 복제본 전체를 선택한다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        // 같은 밀리초에 원본 수정과 복제가 겹치면 목록 순서가 바뀌어 간헐적으로 실패했다. 시각이 반드시 늘어나게 한다.
        let ticks = Counter()
        model.store.clock = { Date(timeIntervalSince1970: 1_800_000_000 + Double(ticks.next())) }
        let a = model.store.createMemo(group: "업무").id
        let b = model.store.createMemo(group: "업무").id
        model.store.updateMeta(id: a) { $0.title = "가나다" }
        model.store.updateMeta(id: b) { $0.title = "라마바" }
        model.scope = .group("업무")
        let positions = model.boardPlacements(for: model.visibleMemos)
        model.selection = [a, b]
        t.expect(model.canDuplicate([a, b]))
        model.duplicate(model.orderedSelection)
        t.expectEqual(model.selection.count, 2)
        t.expect(model.selection.isDisjoint(with: [a, b]))
        t.expectEqual(Set(model.visibleMemos.prefix(2).map(\.id)), model.selection)
        for copy in model.visibleMemos where model.selection.contains(copy.id) {
            let source = copy.meta.title == "가나다 사본" ? a : b
            t.expectEqual(model.store.boardLayout.placement(for: copy.id), positions[source].map { .init(x: $0.x + 24, y: $0.y + 24) })
        }
        var lockedDocument = model.store.loadDocument(id: a)!
        lockedDocument.meta.isLocked = true
        lockedDocument.meta.lockSalt = Data(repeating: 0, count: 16).base64EncodedString()
        lockedDocument.meta.lockVersion = 1
        lockedDocument.body = Data(repeating: 0, count: 28).base64EncodedString()
        try FileMemoRepository(rootDirectory: root, keychain: testKeychain).save(lockedDocument)
        model.store.reloadSummaries()
        t.expect(!model.canDuplicate([a]))
        t.expect(!model.canDuplicate([a, b]))
        let count = model.store.summaries.count
        let selection = model.selection
        model.duplicate([a, b])
        t.expectEqual(model.store.summaries.count, count)
        t.expectEqual(model.selection, selection)
        model.scope = .trash
        t.expect(!model.canDuplicate([b]))
        model.duplicate([b])
        t.expectEqual(model.store.summaries.count, count)
    }
}

runner.test("화면에 뜬 메모와 흐름에서 복제해도 새 메모를 목록에 보여 준다") { t in
    try MainActor.assumeIsolated {
        let (model, windows, root) = try makeModelWithWindows()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = model.store.createMemo().id
        let b = model.store.createMemo().id
        windows.onScreen = [a]
        model.scope = .visible
        model.duplicate([a])
        t.expectEqual(model.scope, .all)
        t.expectEqual(model.orderedSelection.count, 1)
        t.expectEqual(windows.onScreen, [a])
        model.store.link(from: a, to: b, kind: .flow)
        model.scope = .flow(a)
        model.duplicate([a])
        t.expectEqual(model.scope, .all)
        t.expectEqual(model.orderedSelection.count, 1)
    }
}

runner.test("직접 순서는 한 줄과 여러 줄을 보이는 순서대로 옮긴다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<5).map { _ in model.store.createMemo().id }
        model.store.setManualOrder(ids)
        model.sortOrder = MemoSortOrder(key: .manual)
        model.reorder([ids[1]], to: 4)
        t.expectEqual(model.visibleMemos.map(\.id), [ids[0], ids[2], ids[3], ids[1], ids[4]])
        model.reorder([ids[4], ids[2]], to: 0)
        t.expectEqual(model.visibleMemos.map(\.id), [ids[2], ids[4], ids[0], ids[3], ids[1]])
        t.expectEqual(model.bentoOrdered(model.visibleMemos).map(\.id), model.visibleMemos.map(\.id))
        model.reorder([ids[2]], to: 1)
        t.expectEqual(model.visibleMemos.first?.id, ids[2], "자기 자리로 놓으면 순서가 바뀌지 않는다")
    }
}

runner.test("그룹과 검색 안의 이동은 전역 순서에서 그 자리만 바꾸고 직접 순서로 전환한다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<5).map { n in model.store.createMemo(group: n % 2 == 0 ? "업무" : "개인").id }
        for (n, id) in ids.enumerated() { model.store.saveBody(id: id, body: "# 제목 \(n)\n\(n % 2 == 0 ? "업무" : "개인")") }
        model.store.setManualOrder(ids)
        model.sortOrder = MemoSortOrder(key: .title, ascending: false)
        model.scope = .group("업무")
        t.expectEqual(model.visibleMemos.map(\.id), [ids[4], ids[2], ids[0]])
        model.reorder([ids[0]], to: 1)
        t.expectEqual(model.sortOrder.key, .manual)
        t.expectEqual(model.store.boardLayout.manualOrder, [ids[4], ids[1], ids[0], ids[3], ids[2]])
        model.scope = .all
        model.query = "개인"
        model.reorder([ids[3]], to: 0)
        t.expectEqual(model.store.boardLayout.manualOrder, [ids[4], ids[3], ids[0], ids[1], ids[2]])
        model.query = ""
        model.moveByKeyboard(ids[4], direction: 1)
        t.expectEqual(model.visibleMemos.prefix(2).map(\.id), [ids[3], ids[4]])
        model.scope = .trash
        let saved = model.store.boardLayout.manualOrder
        model.reorder([ids[4]], to: 0)
        t.expectEqual(model.store.boardLayout.manualOrder, saved)
        model.scope = .flow(ids[0])
        t.expect(!model.canReorder)
    }
}

runner.test("직접 순서는 새 메모를 맨 위에 놓고 삭제를 정리하며 재시작 뒤 유지된다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = model.store.createMemo().id
        let b = model.store.createMemo().id
        model.store.setManualOrder([a, b])
        model.sortOrder = MemoSortOrder(key: .manual)
        let c = model.store.createMemo().id
        t.expectEqual(model.visibleMemos.map(\.id), [c, a, b])
        model.store.moveToTrash(id: a)
        t.expectEqual(model.store.boardLayout.manualOrder, [c, b])
        let repository = try FileMemoRepository(rootDirectory: root, keychain: testKeychain)
        let restarted = MemoStore(repository: repository, keychain: testKeychain)
        t.expectEqual(restarted.boardLayout.manualOrder, [c, b])
    }
}

runner.test("새로고침은 동기화로 받은 직접 순서를 보존한다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = model.store.createMemo().id
        let b = model.store.createMemo().id
        let repository = try FileMemoRepository(rootDirectory: root, keychain: testKeychain)
        let c = MemoMeta(id: .generate())
        try repository.save(MemoDocument(meta: c, body: "새 메모"))
        try repository.saveBoardLayout(BoardLayout(manualOrder: [b, c.id, a]))
        model.refresh()
        model.sortOrder = MemoSortOrder(key: .manual)
        t.expectEqual(model.visibleMemos.map(\.id), [b, c.id, a])
        t.expectEqual(try repository.loadBoardLayout().manualOrder, [b, c.id, a])
    }
}

runner.test("직접 순서의 벤토는 뒤의 작은 카드로 앞 빈칸을 채우지 않는다") { t in
    let spans: [BoardLayout.BentoSpan] = [.small, .wide, .small]
    let cells = BentoGrid.bentoCells(spans: spans, width: 440, preservingOrder: true).cells
    for pair in zip(cells, cells.dropFirst()) {
        t.expect(pair.0.minY < pair.1.minY || (pair.0.minY == pair.1.minY && pair.0.minX < pair.1.minX))
    }
}

runner.test("보드 연결과 모양 변경은 되돌리고 다시 실행할 수 있다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        let a = model.store.createMemo().id, b = model.store.createMemo().id
        undo.beginUndoGrouping()
        model.link(from: a, to: b, kind: .flow, undoManager: undo)
        undo.endUndoGrouping()
        t.expectEqual(undo.undoActionName, "선 잇기")
        undo.undo()
        t.expectEqual(model.store.edges.count, 0)
        undo.redo()
        t.expectEqual(model.store.edges, [MemoEdge(from: a, to: b, kind: .flow)])
        undo.beginUndoGrouping()
        model.changeLink(model.store.edges[0], kind: .dashboth, undoManager: undo)
        undo.endUndoGrouping()
        t.expectEqual(model.store.edges[0].kind, .dashboth)
        undo.undo()
        t.expectEqual(model.store.edges[0].kind, .flow)
        undo.redo()
        t.expectEqual(model.store.edges[0].kind, .dashboth)
        undo.beginUndoGrouping()
        model.unlink(a, b, undoManager: undo)
        undo.endUndoGrouping()
        undo.undo()
        t.expectEqual(model.store.edges[0].kind, .dashboth)
    }
}

runner.test("보드 여러 카드 이동과 재정렬은 이전 배치를 복원한다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        let a = model.store.createMemo().id, b = model.store.createMemo().id
        let before = model.boardPlacements(for: model.visibleMemos)
        undo.beginUndoGrouping()
        model.moveCards([a: .init(x: 800, y: 600), b: .init(x: 100, y: 200)], undoManager: undo)
        undo.endUndoGrouping()
        let moved = model.store.boardLayout.placements
        undo.undo()
        t.expectEqual(model.boardPlacements(for: model.visibleMemos), before)
        undo.redo()
        t.expectEqual(model.store.boardLayout.placements, moved)
        undo.beginUndoGrouping()
        model.autoArrange(model.visibleMemos, undoManager: undo)
        undo.endUndoGrouping()
        undo.undo()
        t.expectEqual(model.store.boardLayout.placements, moved)
    }
}

runner.test("보드 붙여넣기는 휴지통으로 되돌리고 같은 메모를 복원한다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        model.pasteMemo("붙인 본문", at: .init(x: 40, y: 80), undoManager: undo)
        undo.endUndoGrouping()
        let id = model.store.summaries[0].id
        undo.undo()
        t.expectEqual(model.store.summaries.count, 0)
        t.expectEqual(model.store.trashed.map(\.id), [id])
        undo.redo()
        t.expectEqual(model.store.summaries.map(\.id), [id])
        t.expectEqual(model.store.loadDocument(id: id)?.body, "붙인 본문")
        t.expectEqual(model.store.boardLayout.placement(for: id), .init(x: 40, y: 80))
    }
}

runner.test("보드 내보내기는 잠긴 메모와 선을 빼고 남은 배치로 크기를 계산한다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = model.store.createMemo().id, b = model.store.createMemo().id, locked = model.store.createMemo().id
        var lockedDocument = model.store.loadDocument(id: locked)!
        lockedDocument.meta.isLocked = true
        lockedDocument.meta.title = "숨긴 제목"
        lockedDocument.meta.lockSalt = Data(repeating: 0, count: 16).base64EncodedString()
        lockedDocument.meta.lockVersion = 1
        lockedDocument.body = Data(repeating: 0, count: 28).base64EncodedString()
        try FileMemoRepository(rootDirectory: root, keychain: testKeychain).save(lockedDocument)
        model.store.reloadSummaries()
        model.link(from: a, to: b, kind: .both)
        model.link(from: b, to: locked, kind: .flow)
        let positions: [MemoID: BoardLayout.Placement] = [a: .init(x: -100, y: -60), b: .init(x: 200, y: 120), locked: .init(x: 10000, y: 10000)]
        let content = BoardExportContent(memos: model.visibleMemos, positions: positions, index: model.linkIndex)
        t.expectEqual(Set(content.memos.map(\.id)), Set([a, b]))
        t.expectEqual(content.positions[b], positions[b])
        t.expectEqual(content.excludedCount, 1)
        t.expectEqual(content.edges, [MemoEdge(from: a, to: b, kind: .both)])
        t.expectEqual(content.index.summaries[locked], nil)
        t.expectEqual(content.index.flows.count, 0)
        t.expectEqual(content.size(footer: false), CGSize(width: 580, height: 380))
        t.expectEqual(content.size(footer: true, scale: 2), CGSize(width: 1160, height: 816))
        let large = BoardExportContent(memos: model.visibleMemos, positions: [a: .init(x: 0, y: 0), b: .init(x: 8000, y: 0)], index: model.linkIndex)
        t.expect(large.isTooLarge(footer: true, scale: 2))
        t.expect(!large.isTooLarge(footer: true, scale: 1))
    }
}

runner.test("보드 화살표는 양 끝에 길이 10 폭 9 삼각형을 그린다") { t in
    let a = MemoID.generate(), b = MemoID.generate()
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
    for kind in MemoLinkKind.allCases {
        let geometry = PipeGeometry(edge: MemoEdge(from: a, to: b, kind: kind), points: points)
        t.expectEqual(geometry.arrow.isEmpty, kind.arrows == .none)
        if kind.arrows != .none {
            t.expectEqual(geometry.arrow.boundingRect.height, 9)
            t.expectEqual(geometry.arrow.boundingRect.width, kind.arrows == .both ? 100 : 10)
        }
    }
}

runner.test("선 이름 변경과 지우기는 되돌릴 수 있고 종류 변경에도 보존된다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = model.store.createMemo().id, b = model.store.createMemo().id
        model.link(from: a, to: b, kind: .flow)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        model.renameLink(model.store.edges[0], label: "검토 후", undoManager: undo)
        undo.endUndoGrouping()
        t.expectEqual(undo.undoActionName, "선 이름 바꾸기")
        t.expectEqual(model.store.edges[0].displayLabel, "흐름 · 검토 후")
        undo.undo()
        t.expectEqual(model.store.edges[0].label, "")
        undo.redo()
        model.changeLink(model.store.edges[0], kind: .contain)
        t.expectEqual(model.store.edges[0].displayLabel, "포함 · 검토 후")
        undo.beginUndoGrouping()
        model.renameLink(model.store.edges[0], label: "", undoManager: undo)
        undo.endUndoGrouping()
        t.expectEqual(model.store.edges[0].displayLabel, "포함")
        undo.undo()
        t.expectEqual(model.store.edges[0].label, "검토 후")
    }
}
runner.test("짧은 선의 이름표는 카드 위로 옮긴다") { t in
    let edge = MemoEdge(from: .generate(), to: .generate(), kind: .flow, label: "검토 후")
    let cards = [CGRect(x: 0, y: 0, width: 200, height: 120), CGRect(x: 210, y: 0, width: 200, height: 120)]
    let pipe = PipeGeometry(edge: edge, a: cards[0], b: cards[1])
    let point = pipe.labelPoint(avoiding: cards)
    t.expect(point.y < 0)
    t.expectEqual(point.x, pipe.midpoint.x)
}

runner.test("저장된 카드를 옮겨도 미저장 카드 자리를 고정하고 되돌리기로 전체 저장 상태를 복원한다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<3 { model.store.createMemo() }
        let memos = model.visibleMemos, id = memos[0].id
        model.moveCard(id, to: .init(x: 40, y: 100))
        let saved = model.store.boardLayout.placements
        let before = model.boardPlacements(for: memos)
        let undo = UndoManager()
        undo.beginUndoGrouping()
        model.moveCards([id: .init(x: 53, y: 913)], freezing: memos, undoManager: undo)
        undo.endUndoGrouping()
        let after = model.boardPlacements(for: memos)
        t.expectEqual(after[id], .init(x: 60, y: 920))
        for memo in memos.dropFirst() { t.expectEqual(after[memo.id], before[memo.id]) }
        t.expectEqual(model.store.boardLayout.placements.count, 3)
        undo.undo()
        t.expectEqual(model.store.boardLayout.placements, saved)
        t.expectEqual(model.boardPlacements(for: memos), before)
        undo.redo()
        t.expectEqual(model.boardPlacements(for: memos), after)
    }
}

runner.test("단계별 배치는 분기와 순환에서도 결정적이며 카드가 겹치지 않는다") { t in
    try MainActor.assumeIsolated {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<12).map { _ in model.store.createMemo().id }
        for (a, b) in [(0, 1), (0, 2), (1, 3), (2, 3), (4, 5), (5, 6), (6, 4)] {
            model.link(from: ids[a], to: ids[b], kind: .flow)
        }
        let memos = ids.compactMap { id in model.store.summaries.first { $0.id == id } }
        let positions = model.autoArrangedPlacements(for: memos)
        t.expectEqual(positions, model.autoArrangedPlacements(for: memos))
        t.expectEqual(positions[ids[1]]!.x, positions[ids[2]]!.x)
        t.expect(abs(positions[ids[1]]!.y - positions[ids[2]]!.y) >= 200)
        for i in ids.indices { for j in ids.indices where j > i {
            let a = positions[ids[i]]!, b = positions[ids[j]]!
            t.expect(!CGRect(x: a.x, y: a.y, width: 200, height: 120).intersects(CGRect(x: b.x, y: b.y, width: 200, height: 120)))
        } }
    }
}

runner.test("격자 길찾기는 장애물을 피하고 같은 변의 포트를 상대 위치 순으로 나눈다") { t in
    let ids = (0..<4).map { _ in MemoID.generate() }
    let positions: [MemoID: BoardLayout.Placement] = [ids[0]: .init(x: 0, y: 200), ids[1]: .init(x: 840, y: 0),
        ids[2]: .init(x: 840, y: 400), ids[3]: .init(x: 420, y: 200)]
    let edges = [MemoEdge(from: ids[0], to: ids[2], kind: .flow), MemoEdge(from: ids[0], to: ids[1], kind: .flow)]
    let pipes = PipeGeometry.make(edges: edges, positions: positions)
    t.expectEqual(pipes.count, 2)
    // 상대 카드 쪽으로 가장 가까운 자리: 위 카드로 가는 선은 위 끝, 아래 카드로 가는 선은 아래 끝.
    t.expectEqual(pipes[0].points.first, CGPoint(x: 200, y: 300))
    t.expectEqual(pipes[1].points.first, CGPoint(x: 200, y: 220))
    t.expectEqual(pipes.map(\.points), PipeGeometry.make(edges: edges, positions: positions).map(\.points))
    for pipe in pipes {
        for (a, b) in zip(pipe.points, pipe.points.dropFirst()) {
            t.expect(a.x == b.x || a.y == b.y)
            let obstacle = CGRect(x: 410, y: 190, width: 220, height: 140)
            if a.y == b.y && a.y > obstacle.minY && a.y < obstacle.maxY {
                t.expect(max(a.x, b.x) <= obstacle.minX || min(a.x, b.x) >= obstacle.maxX)
            }
            if a.x == b.x && a.x > obstacle.minX && a.x < obstacle.maxX {
                t.expect(max(a.y, b.y) <= obstacle.minY || min(a.y, b.y) >= obstacle.maxY)
            }
        }
        for i in pipe.points.indices.dropFirst().dropLast() {
            let a = pipe.points[i - 1], b = pipe.points[i], c = pipe.points[i + 1]
            t.expect(!(a.x == b.x && b.x == c.x) && !(a.y == b.y && b.y == c.y))
        }
    }
}

runner.test("나란한 두 카드 사이 선은 한 변에 선이 여럿이어도 곧게 간다") { t in
    let ids = (0..<3).map { _ in MemoID.generate() }
    let positions: [MemoID: BoardLayout.Placement] = [ids[0]: .init(x: 0, y: 0), ids[1]: .init(x: 280, y: 0), ids[2]: .init(x: 0, y: 200)]
    let edges = [MemoEdge(from: ids[0], to: ids[1], kind: .flow), MemoEdge(from: ids[1], to: ids[2], kind: .flow)]
    let pipes = PipeGeometry.make(edges: edges, positions: positions)
    t.expectEqual(pipes[0].points, [CGPoint(x: 200, y: 60), CGPoint(x: 280, y: 60)])
}

runner.test("길찾기는 국소 범위 바깥으로 재시도하고 막히면 기존 경로로 돌아간다") { t in
    let a = MemoID.generate(), b = MemoID.generate()
    let edge = MemoEdge(from: a, to: b, kind: .flow)
    var positions: [MemoID: BoardLayout.Placement] = [a: .init(x: 0, y: 0), b: .init(x: 840, y: 0)]
    let wall = stride(from: -600, through: 600, by: 120).map { y in
        (MemoID.generate(), BoardLayout.Placement(x: 420, y: Double(y)))
    }
    for (id, p) in wall { positions[id] = p }
    let pipe = PipeGeometry.make(edges: [edge], positions: positions)[0]
    t.expect(pipe.points.contains { $0.y < -600 || $0.y > 720 })
    t.expectEqual(pipe.points.first, CGPoint(x: 200, y: 60))
    t.expectEqual(pipe.points.last, CGPoint(x: 840, y: 60))
    let blocked: [MemoID: BoardLayout.Placement] = [a: .init(x: 0, y: 0), b: .init(x: 840, y: 0),
        MemoID.generate(): .init(x: 200, y: 0)]
    let fallback = PipeGeometry(edge: edge, a: CGRect(x: 0, y: 0, width: 200, height: 120),
                                b: CGRect(x: 840, y: 0, width: 200, height: 120))
    t.expectEqual(PipeGeometry.make(edges: [edge], positions: blocked)[0].points, fallback.points)
    let diagonal: [MemoID: BoardLayout.Placement] = [a: .init(x: 0, y: 0), b: .init(x: 280, y: 220)]
    let vertical = PipeGeometry.make(edges: [edge], positions: diagonal)[0]
    t.expectEqual(vertical.points.first, CGPoint(x: 100, y: 120))
    t.expectEqual(vertical.points.last, CGPoint(x: 380, y: 220))
}

runner.test("이름표 중점은 전체 길이의 절반이고 엇갈림은 양쪽 구간 안쪽만 센다") { t in
    let edge = MemoEdge(from: .generate(), to: .generate(), kind: .flow)
    let pipe = PipeGeometry(edge: edge, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 20), CGPoint(x: 300, y: 20)])
    t.expectEqual(pipe.midpoint, CGPoint(x: 140, y: 20))
    let horizontal = PipeGeometry(edge: edge, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
    let vertical = PipeGeometry(edge: edge, points: [CGPoint(x: 50, y: -40), CGPoint(x: 50, y: 40)])
    let touching = PipeGeometry(edge: edge, points: [CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 40)])
    let crossings = PipeGeometry.crossings(in: [horizontal, vertical, touching])
    t.expectEqual(crossings.count, 1)
    t.expectEqual(crossings.first?.point, CGPoint(x: 50, y: 0))
    t.expectEqual(crossings.first?.horizontalPipe, 0)
    t.expectEqual(crossings.first?.segment, 0)
}

runner.test("큰 보드의 150개 메모와 200개 선 길찾기 시간을 출력한다") { t in
    let ids = (0..<150).map { _ in MemoID.generate() }
    let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { i, id in
        (id, BoardLayout.Placement(x: Double(i % 15) * 400, y: Double(i / 15) * 400))
    })
    let edges = (0..<200).map { i in
        MemoEdge(from: ids[i % 150], to: ids[(i * 37 + 17) % 150], kind: i % 2 == 0 ? .flow : .related)
    }
    let start = Date()
    let pipes = PipeGeometry.make(edges: edges, positions: positions)
    print("  큰 보드 길찾기: \(Int(Date().timeIntervalSince(start) * 1000)) ms (메모 150, 선 200, 범위 약 6000×4000)")
    t.expectEqual(pipes.count, 200)
}

runner.finish()
