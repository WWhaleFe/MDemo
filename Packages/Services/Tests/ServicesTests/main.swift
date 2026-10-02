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

// MARK: - 백업과 내보내기 (DAT-04 ~ DAT-07)

runner.test("백업을 만들고 되돌리면 메모가 그대로 돌아온다 (DAT-04, DAT-05)") { t in
    try MainActor.assumeIsolated {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let dataRoot = base.appendingPathComponent("Data", isDirectory: true)
        let repository = try FileMemoRepository(rootDirectory: dataRoot)
        let store = MemoStore(repository: repository)
        let backup = BackupService(dataRoot: dataRoot)

        let meta = store.createMemo(group: "업무")
        store.saveBody(id: meta.id, body: "# 중요한 메모\n- [ ] 잃어버리면 안 됨")

        let archive = base.appendingPathComponent("backup.zip")
        try backup.exportBackup(to: archive)
        t.expect(FileManager.default.fileExists(atPath: archive.path), "백업 파일이 만들어지지 않았다")

        // 실수로 다 지운 상황을 만든다
        store.moveToTrash(id: meta.id)
        store.emptyTrash()
        t.expectEqual(store.summaries.count, 0)

        try backup.importBackup(from: archive, replaceExisting: true)
        store.reloadSummaries()
        t.expectEqual(store.summaries.count, 1, "복원되지 않았다")
        t.expectEqual(store.loadDocument(id: meta.id)?.body, "# 중요한 메모\n- [ ] 잃어버리면 안 됨")
        t.expectEqual(store.summaries.first?.meta.group, "업무", "그룹까지 돌아와야 한다")
    }
}

runner.test("합치기로 복원하면 지금 메모가 지워지지 않는다 (DAT-05)") { t in
    try MainActor.assumeIsolated {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BackupMerge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let dataRoot = base.appendingPathComponent("Data", isDirectory: true)
        let repository = try FileMemoRepository(rootDirectory: dataRoot)
        let store = MemoStore(repository: repository)
        let backup = BackupService(dataRoot: dataRoot)

        let old = store.createMemo()
        store.saveBody(id: old.id, body: "예전 메모")

        let archive = base.appendingPathComponent("backup.zip")
        try backup.exportBackup(to: archive)

        let recent = store.createMemo()
        store.saveBody(id: recent.id, body: "백업 뒤에 쓴 메모")

        try backup.importBackup(from: archive, replaceExisting: false)
        store.reloadSummaries()

        t.expectEqual(store.summaries.count, 2, "합치기인데 개수가 맞지 않는다")
        t.expectEqual(store.loadDocument(id: recent.id)?.body, "백업 뒤에 쓴 메모", "나중 메모가 사라졌다")
    }
}

runner.test("메모를 마크다운·HTML·텍스트로 내보낸다 (DAT-06)") { t in
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ExportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let backup = BackupService(dataRoot: base)
    let document = MemoDocument(
        meta: MemoMeta(id: .generate()),
        body: "# 장보기\n- [ ] 우유\n**중요**한 것"
    )

    let markdown = base.appendingPathComponent("memo.md")
    try backup.export(document, as: .markdown, to: markdown)
    t.expectEqual(try String(contentsOf: markdown, encoding: .utf8), document.body, "마크다운은 본문 그대로여야 한다")

    let html = base.appendingPathComponent("memo.html")
    try backup.export(document, as: .html, to: html)
    let htmlText = try String(contentsOf: html, encoding: .utf8)
    t.expect(htmlText.contains("<h1>장보기</h1>"), "제목이 변환되지 않았다")
    t.expect(htmlText.contains("<strong>중요</strong>"), "굵게가 변환되지 않았다")
    t.expect(htmlText.contains("☐"), "체크박스가 변환되지 않았다")

    let plain = base.appendingPathComponent("memo.txt")
    try backup.export(document, as: .plainText, to: plain)
    let plainText = try String(contentsOf: plain, encoding: .utf8)
    t.expect(!plainText.contains("#"), "텍스트에 기호가 남았다")
    t.expect(!plainText.contains("**"), "텍스트에 기호가 남았다")
    t.expect(plainText.contains("장보기"), "내용이 사라졌다")
}

runner.test("마크다운 파일을 메모로 가져온다 (DAT-07)") { t in
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ImportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let backup = BackupService(dataRoot: base)

    // 제목이 없는 파일은 파일 이름을 제목으로 삼는다
    let plain = base.appendingPathComponent("회의 준비.txt")
    try Data("안건 정리\n자료 인쇄".utf8).write(to: plain)
    let fromPlain = try backup.makeDocument(fromImportedFile: plain)
    t.expect(fromPlain.body.hasPrefix("# 회의 준비"), "파일 이름이 제목이 되지 않았다")
    t.expectEqual(fromPlain.meta.isOpen, false, "가져온 메모가 곧바로 뜨면 산만하다")

    // 이미 제목이 있으면 그대로 둔다
    let markdown = base.appendingPathComponent("메모.md")
    try Data("# 원래 제목\n내용".utf8).write(to: markdown)
    let fromMarkdown = try backup.makeDocument(fromImportedFile: markdown)
    t.expectEqual(fromMarkdown.body, "# 원래 제목\n내용")
}

// MARK: - MemoApp → MDemo 옮겨 오기

runner.test("예전 MemoApp 폴더와 설정을 MDemo로 한 번만 옮겨 온다") { t in
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MDemoMigrationTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Application Support", isDirectory: true)
    let cloud = root.appendingPathComponent("CloudDocs", isDirectory: true)
    let oldMemo = support.appendingPathComponent("MemoApp/Data/memos/A/memo.md")
    try FileManager.default.createDirectory(at: oldMemo.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "# 예전 메모".write(to: oldMemo, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: cloud.appendingPathComponent("MemoApp"), withIntermediateDirectories: true)

    let suite = "MDemoMigrationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(24.0, forKey: "editor.fontSize")   // 새 앱에서 이미 정한 값은 덮어쓰지 않는다

    let report = LegacyMigration.run(
        applicationSupport: support,
        iCloudDrive: cloud,
        legacyDefaults: ["editor.fontSize": 18.0, "memo.hoverOpaque": false],
        defaults: defaults
    )
    t.expect(report.copiedLocalData, "로컬 데이터를 옮기지 않았다")
    t.expect(report.copiedICloudData, "iCloud 폴더를 옮기지 않았다")
    let newMemo = support.appendingPathComponent("MDemo/Data/memos/A/memo.md")
    t.expectEqual(try? String(contentsOf: newMemo, encoding: .utf8), "# 예전 메모")
    t.expect(FileManager.default.fileExists(atPath: oldMemo.path), "원본을 지우면 안 된다")
    t.expectEqual(defaults.double(forKey: "editor.fontSize"), 24.0, "새 앱의 설정을 덮어썼다")
    t.expectEqual(defaults.object(forKey: "memo.hoverOpaque") as? Bool, false, "예전 설정을 옮기지 않았다")
    t.expectEqual(report.copiedSettingsCount, 1)

    // 두 번째 실행에서는 아무것도 하지 않는다 — 옮긴 뒤 바꾼 값을 되돌리면 안 된다.
    defaults.set(true, forKey: "memo.hoverOpaque")
    let again = LegacyMigration.run(
        applicationSupport: support,
        iCloudDrive: cloud,
        legacyDefaults: ["memo.hoverOpaque": false],
        defaults: defaults
    )
    t.expect(!again.copiedLocalData && !again.copiedICloudData, "두 번째에도 폴더를 건드렸다")
    t.expectEqual(defaults.object(forKey: "memo.hoverOpaque") as? Bool, true, "두 번째 실행에서 설정을 되돌렸다")
}

runner.finish()
