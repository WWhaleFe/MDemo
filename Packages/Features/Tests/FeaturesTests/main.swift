import Features
import Foundation
import MemoCore
import TestKit

// 리스트 창이 "무엇을 보여 줄지" 정하는 규칙을 확인한다.
// 화면 없이 시험할 수 있게 계산을 모델로 빼 둔 덕에 여기서 다 잡힌다.

let runner = TestRunner("Features")

@MainActor
func makeModel() throws -> (MemoListModel, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MemoAppFeatureTests-\(UUID().uuidString)", isDirectory: true)
    let repository = try FileMemoRepository(rootDirectory: root)
    return (MemoListModel(store: MemoStore(repository: repository)), root)
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
        .appendingPathComponent("MemoAppFeatureTests-\(UUID().uuidString)", isDirectory: true)
    let repository = try FileMemoRepository(rootDirectory: root)
    let windows = FakeWindows()
    let model = MemoListModel(store: MemoStore(repository: repository), windowActions: windows.actions)
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

runner.finish()
