import Foundation
import MemoCore
import Services
import TestKit

let runner = TestRunner("Services")

runner.test("메모리 사용량을 읽을 수 있다 (§4-5 측정 게이트의 기반)") { t in
    let bytes = MemoryReporter.footprintBytes()
    t.expectNotNil(bytes, "메모리 측정 실패")
    t.expect((bytes ?? 0) > 1_000_000, "프로세스 메모리가 1MB 미만일 수는 없다")
    t.expect(MemoryReporter.formattedFootprint().hasSuffix("MB"), "표시 형식이 MB가 아님")
}

// MARK: - iCloud 동기화 (SYNC-*)
//
// 폴더 세 개로 기기 두 대를 흉내 낸다: 맥미니 · 맥북 · 그 사이의 iCloud 폴더.
// 실제로 두 대를 놓고 시험할 수 없으니, 같은 폴더를 사이에 둔 두 저장소로 확인한다.

@MainActor
final class FakeDevice {
    let root: URL
    let store: MemoStore
    let sync: SyncService

    init(name: String, base: URL, cloud: URL) throws {
        self.root = base.appendingPathComponent(name, isDirectory: true)
        let repository = try FileMemoRepository(rootDirectory: root)
        self.store = MemoStore(repository: repository)
        self.sync = SyncService(
            localRoot: root,
            remoteRoot: cloud,
            stateURL: root.appendingPathComponent("sync-state.json")
        )
    }

    func reload() {
        store.reloadSummaries()
        store.reloadGroups()
        store.reloadTrash()
    }
}

@MainActor
func makeTwoDevices() throws -> (FakeDevice, FakeDevice, URL) {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SyncTests-\(UUID().uuidString)", isDirectory: true)
    let cloud = base.appendingPathComponent("iCloud", isDirectory: true)
    return (try FakeDevice(name: "맥미니", base: base, cloud: cloud),
            try FakeDevice(name: "맥북", base: base, cloud: cloud),
            base)
}

runner.test("한쪽에서 만든 메모가 다른 쪽으로 건너간다 (SYNC-02, SYNC-03)") { t in
    try MainActor.assumeIsolated {
        let (mini, book, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "# 장보기\n- [ ] 우유")

        let pushReport = try mini.sync.sync(mode: .push)
        t.expectEqual(pushReport.pushed, 1, "올리지 못했다")

        let pullReport = try book.sync.sync(mode: .pull)
        t.expectEqual(pullReport.pulled, 1, "내려받지 못했다")

        book.reload()
        t.expectEqual(book.store.summaries.count, 1, "맥북에 메모가 없다")
        t.expectEqual(book.store.loadDocument(id: meta.id)?.body, "# 장보기\n- [ ] 우유", "본문이 다르다")
    }
}

runner.test("고친 내용이 반대쪽에도 반영된다") { t in
    try MainActor.assumeIsolated {
        let (mini, book, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "처음 내용")
        _ = try mini.sync.sync()
        _ = try book.sync.sync()
        book.reload()

        // 맥북에서 고친 뒤 되돌려 보낸다
        book.store.saveBody(id: meta.id, body: "맥북에서 고친 내용")
        _ = try book.sync.sync()
        let report = try mini.sync.sync()

        t.expectEqual(report.pulled, 1, "고친 내용을 받지 못했다")
        mini.reload()
        t.expectEqual(mini.store.loadDocument(id: meta.id)?.body, "맥북에서 고친 내용")
    }
}

runner.test("양쪽에서 동시에 고치면 최신본이 남고 진 쪽은 사본으로 보존된다 (SYNC-06)") { t in
    try MainActor.assumeIsolated {
        let (mini, book, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "원래 내용")
        _ = try mini.sync.sync()
        _ = try book.sync.sync()
        book.reload()

        // 양쪽에서 각각 고친다. 맥북 쪽이 더 나중이 되도록 순서를 둔다.
        mini.store.saveBody(id: meta.id, body: "맥미니가 고친 내용")
        Thread.sleep(forTimeInterval: 0.01)
        book.store.saveBody(id: meta.id, body: "맥북이 고친 내용")

        _ = try mini.sync.sync()          // 맥미니 것이 먼저 올라간다
        let report = try book.sync.sync() // 맥북에서 충돌을 발견한다

        t.expectEqual(report.conflicts, 1, "충돌 사본이 만들어지지 않았다")

        book.reload()
        t.expectEqual(book.store.loadDocument(id: meta.id)?.body, "맥북이 고친 내용", "최신본이 남아야 한다")

        let copies = book.store.summaries.filter { $0.meta.conflictOf != nil }
        t.expectEqual(copies.count, 1, "사본이 목록에 없다")
        let copyBody = copies.first.flatMap { book.store.loadDocument(id: $0.id)?.body }
        t.expectEqual(copyBody, "맥미니가 고친 내용", "진 쪽 내용이 보존되지 않았다")
    }
}

runner.test("한쪽에서 버리면 다른 쪽에서도 휴지통으로 간다 (TRS-01, SYNC-06)") { t in
    try MainActor.assumeIsolated {
        let (mini, book, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "버릴 메모")
        _ = try mini.sync.sync()
        _ = try book.sync.sync()
        book.reload()
        t.expectEqual(book.store.summaries.count, 1)

        mini.store.moveToTrash(id: meta.id)
        _ = try mini.sync.sync()
        let report = try book.sync.sync()

        t.expectEqual(report.deletions, 1, "삭제가 전파되지 않았다")
        book.reload()
        t.expectEqual(book.store.summaries.count, 0, "목록에 남아 있다")
        t.expectEqual(book.store.trashed.count, 1, "휴지통에 없다 — 되돌릴 수 없게 됐다")
    }
}

runner.test("창을 띄운 상태가 기기 간에 공유된다 (SYNC-08)") { t in
    try MainActor.assumeIsolated {
        let (mini, book, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.setOpen(id: meta.id, isOpen: true)
        _ = try mini.sync.sync()
        _ = try book.sync.sync()
        book.reload()

        t.expectEqual(book.store.openMemos.count, 1, "맥북에서도 떠 있어야 한다")

        mini.store.setOpen(id: meta.id, isOpen: false)
        _ = try mini.sync.sync()
        _ = try book.sync.sync()
        book.reload()

        t.expectEqual(book.store.openMemos.count, 0, "닫은 것이 전해지지 않았다")
    }
}

runner.test("그룹 목록은 양쪽 것을 합친다") { t in
    try MainActor.assumeIsolated {
        let (mini, book, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        mini.store.createGroup(named: "업무")
        book.store.createGroup(named: "개인")

        _ = try mini.sync.sync()
        _ = try book.sync.sync()
        _ = try mini.sync.sync()

        mini.reload()
        book.reload()
        t.expect(mini.store.groups.contains("업무") && mini.store.groups.contains("개인"), "맥미니에 합쳐지지 않았다")
        t.expect(book.store.groups.contains("업무") && book.store.groups.contains("개인"), "맥북에 합쳐지지 않았다")
    }
}

runner.test("바뀐 것이 없으면 아무 일도 하지 않는다") { t in
    try MainActor.assumeIsolated {
        let (mini, book, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        mini.store.createMemo()
        _ = try mini.sync.sync()
        _ = try book.sync.sync()

        let again = try mini.sync.sync()
        t.expect(again.isEmpty, "할 일이 없는데 무언가를 했다: \(again.summary)")
        t.expectEqual(again.summary, "변경 없음")
    }
}

runner.test("불러오기만 하면 내 변경이 올라가지 않는다 (SYNC-02, SYNC-03 분리)") { t in
    try MainActor.assumeIsolated {
        let (mini, book, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        mini.store.createMemo()
        let pullOnly = try mini.sync.sync(mode: .pull)
        t.expectEqual(pullOnly.pushed, 0, "불러오기인데 올렸다")

        _ = try book.sync.sync(mode: .pull)
        book.reload()
        t.expectEqual(book.store.summaries.count, 0, "올리지 않았는데 건너갔다")
    }
}

runner.finish()
