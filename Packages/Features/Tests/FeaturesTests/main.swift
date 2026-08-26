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

runner.finish()
