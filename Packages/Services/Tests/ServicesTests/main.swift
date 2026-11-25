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

runner.test("board.json은 한쪽만 있으면 복사하고 양쪽이면 최신 파일로 맞춘다 (SYNC-06)") { t in
    try MainActor.assumeIsolated {
        let (mini, book, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = MemoID.generate()
        let local = mini.root.appendingPathComponent("board.json")
        let remote = mini.sync.remoteRoot.appendingPathComponent("board.json")
        mini.store.setBoardPlacement(.init(x: 10, y: 20), for: id)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: local.path)
        _ = try mini.sync.sync(mode: .push)
        t.expectEqual(try Data(contentsOf: local), try Data(contentsOf: remote))
        _ = try book.sync.sync(mode: .pull)
        book.store.reloadBoardLayout()
        t.expectEqual(book.store.boardLayout, mini.store.boardLayout)
        let remoteRepository = try FileMemoRepository(rootDirectory: mini.sync.remoteRoot)
        let newer = BoardLayout(placements: [id.rawValue: .init(x: 30, y: 40)])
        try remoteRepository.saveBoardLayout(newer)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: remote.path)
        _ = try mini.sync.sync(mode: .push)
        t.expectEqual(try remoteRepository.loadBoardLayout(), newer, "push가 최신 원격 파일을 덮어썼다")
        _ = try mini.sync.sync()
        mini.store.reloadBoardLayout()
        t.expectEqual(mini.store.boardLayout, newer)
        mini.store.setBentoSpan(.wide, for: id)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: local.path)
        _ = try mini.sync.sync(mode: .pull)
        t.expectEqual(try remoteRepository.loadBoardLayout(), newer)
        _ = try mini.sync.sync()
        t.expectEqual(try remoteRepository.loadBoardLayout(), mini.store.boardLayout)
        let stamp = try remote.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try mini.sync.sync()
        t.expectEqual(try remote.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, stamp)
        let state = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: mini.root.appendingPathComponent("sync-state.json")))
        t.expectEqual(state["board.json"], Date(timeIntervalSince1970: 300))
    }
}

runner.test("화면 모드는 기본이 시스템이고 저장하면 다시 읽힌다") { t in
    MainActor.assumeIsolated {
        let suite = "MDemoAppearanceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppPreferences(store: defaults)
        t.expectEqual(first.appearanceMode, .system)
        first.appearanceMode = .dark
        t.expectEqual(AppPreferences(store: defaults).appearanceMode, .dark)
        first.appearanceMode = .light
        t.expectEqual(AppPreferences(store: defaults).appearanceMode, .light)
        defaults.set("엉뚱한 값", forKey: "app.appearance")
        t.expectEqual(AppPreferences(store: defaults).appearanceMode, .system)
    }
}

// MARK: - AirDrop 받기: 다 써질 때까지 기다림

@MainActor
func makeDownloadsFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

runner.test("Downloads 감시: 시작 전에 있던 파일과 이미지가 아닌 파일, 숨김 파일은 받지 않는다") { t in
    try MainActor.assumeIsolated {
        let folder = try makeDownloadsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("old.png"))
        let scanner = DownloadsScanner(directory: folder, settleInterval: 0.5)
        scanner.begin()
        try Data([1]).write(to: folder.appendingPathComponent("notes.txt"))
        try Data([1]).write(to: folder.appendingPathComponent(".hidden.png"))
        let start = Date()
        t.expectEqual(scanner.scan(now: start).count, 0)
        t.expectEqual(scanner.scan(now: start.addingTimeInterval(2)).count, 0)
        t.expect(!scanner.hasPending, "받을 게 없는데 기다리는 중")
    }
}

runner.test("Downloads 감시: 크기가 0.5초 동안 그대로여야 받는다") { t in
    try MainActor.assumeIsolated {
        let folder = try makeDownloadsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scanner = DownloadsScanner(directory: folder, settleInterval: 0.5)
        scanner.begin()
        let file = folder.appendingPathComponent("IMG_1.HEIC")
        let start = Date()

        // 쓰는 중: 크기가 바뀔 때마다 기다림이 처음부터다.
        try Data(repeating: 1, count: 10).write(to: file)
        t.expectEqual(scanner.scan(now: start).count, 0)
        t.expect(scanner.hasPending)
        try Data(repeating: 1, count: 20).write(to: file)
        t.expectEqual(scanner.scan(now: start.addingTimeInterval(0.4)).count, 0, "크기가 바뀌었는데 받았다")
        t.expectEqual(scanner.scan(now: start.addingTimeInterval(0.8)).count, 0, "바뀐 뒤 0.5초가 안 지났다")
        let ready = scanner.scan(now: start.addingTimeInterval(1.0))
        t.expectEqual(ready.map(\.lastPathComponent), ["IMG_1.HEIC"])
        // 한 번 받은 파일은 다시 오지 않는다.
        t.expectEqual(scanner.scan(now: start.addingTimeInterval(5)).count, 0)
        t.expect(!scanner.hasPending)
        t.expect(FileManager.default.fileExists(atPath: file.path), "원본이 지워졌다")
    }
}

runner.test("Downloads 감시: 빈 파일은 기다리고, 여러 장은 모두 받는다") { t in
    try MainActor.assumeIsolated {
        let folder = try makeDownloadsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scanner = DownloadsScanner(directory: folder, settleInterval: 0.5)
        scanner.begin()
        let start = Date()
        try Data().write(to: folder.appendingPathComponent("empty.jpg"))
        try Data([1, 2]).write(to: folder.appendingPathComponent("a.png"))
        try Data([1, 2]).write(to: folder.appendingPathComponent("b.jpeg"))
        _ = scanner.scan(now: start)
        let ready = scanner.scan(now: start.addingTimeInterval(1))
        t.expectEqual(Set(ready.map(\.lastPathComponent)), ["a.png", "b.jpeg"])
        t.expect(scanner.hasPending, "빈 파일은 계속 기다려야 한다")
        try Data([9]).write(to: folder.appendingPathComponent("empty.jpg"))
        _ = scanner.scan(now: start.addingTimeInterval(1.1))
        t.expectEqual(scanner.scan(now: start.addingTimeInterval(2)).map(\.lastPathComponent), ["empty.jpg"])
    }
}

runner.test("Downloads 감시: 지켜보던 파일이 사라지면 기다림을 접는다") { t in
    try MainActor.assumeIsolated {
        let folder = try makeDownloadsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scanner = DownloadsScanner(directory: folder, settleInterval: 0.5)
        scanner.begin()
        let file = folder.appendingPathComponent("gone.png")
        try Data([1]).write(to: file)
        _ = scanner.scan(now: Date())
        try FileManager.default.removeItem(at: file)
        _ = scanner.scan(now: Date().addingTimeInterval(1))
        t.expect(!scanner.hasPending)
    }
}

runner.test("AirDrop 받기: 폴더에 생긴 사진을 알려 주고, 멈추면 더는 알리지 않는다") { t in
    try MainActor.assumeIsolated {
        let folder = try makeDownloadsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let receiver = AirDropReceiver(directory: folder, duration: 30, settleInterval: 0.05)
        var received: [String] = []
        var finished: Int?
        receiver.onReceive = { received.append($0.lastPathComponent) }
        receiver.onFinish = { finished = $0 }
        receiver.start()
        t.expect(receiver.isActive)
        t.expectEqual(receiver.remainingSeconds, 30)

        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("p1.png"))
        // 실행 루프를 돌려 감시기가 깨어나게 한다.
        let deadline = Date().addingTimeInterval(3)
        while received.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        t.expectEqual(received, ["p1.png"])
        t.expectEqual(receiver.receivedCount, 1)

        receiver.stop()
        t.expect(!receiver.isActive)
        t.expectEqual(finished, 1)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("p2.png"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        t.expectEqual(received, ["p1.png"], "멈춘 뒤에도 받았다")
    }
}

// MARK: - 다른 앱에서 고친 것 알아채기 (지문)

/// 메모 파일 경로.
func memoFile(_ root: URL, _ id: MemoID, trash: Bool = false) -> URL {
    root.appendingPathComponent(trash ? "trash" : "memos", isDirectory: true)
        .appendingPathComponent(id.rawValue, isDirectory: true)
        .appendingPathComponent("memo.md")
}

/// 다른 편집기가 한 것처럼 프론트매터는 그대로 두고 본문만 바꾼다.
func editOutside(_ url: URL, replacing old: String, with new: String, mtime: Date) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    try Data(text.replacingOccurrences(of: old, with: new).utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
}

runner.test("modified가 그대로인 바깥 편집도 알아채 반대쪽에 전파한다") { t in
    try MainActor.assumeIsolated {
        let (mini, book, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "처음 내용")
        _ = try mini.sync.sync()
        _ = try book.sync.sync()

        let stamp = Date().addingTimeInterval(3600)
        try editOutside(memoFile(mini.root, meta.id), replacing: "처음 내용", with: "파일 앱에서 고침", mtime: stamp)

        let pushed = try mini.sync.sync()
        t.expectEqual(pushed.pushed, 1, "바깥 편집이 올라가지 않았다")
        t.expectEqual(pushed.conflicts, 0)

        let pulled = try book.sync.sync()
        t.expectEqual(pulled.pulled, 1, "바깥 편집이 내려오지 않았다")
        book.reload()
        let document = book.store.loadDocument(id: meta.id)
        t.expectEqual(document?.body, "파일 앱에서 고침", "본문이 다르다")
        let modified = document?.meta.modified.timeIntervalSince1970 ?? 0
        t.expect(abs(modified - stamp.timeIntervalSince1970) < 0.01, "modified가 파일 수정 시각으로 고쳐지지 않았다")

        // 되돌아 복사되며 맴돌지 않는다.
        t.expect(try mini.sync.sync().isEmpty, "맥미니가 또 움직였다")
        t.expect(try book.sync.sync().isEmpty, "맥북이 또 움직였다")
        t.expect(try mini.sync.sync().isEmpty, "맥미니가 또 움직였다 (2)")
    }
}

runner.test("iCloud 쪽 파일을 바깥에서 고쳐도 내려받고 맴돌지 않는다") { t in
    try MainActor.assumeIsolated {
        let (mini, _, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "처음 내용")
        _ = try mini.sync.sync()

        try editOutside(memoFile(mini.sync.remoteRoot, meta.id), replacing: "처음 내용", with: "아이폰에서 고침",
                        mtime: Date().addingTimeInterval(3600))
        let report = try mini.sync.sync()
        t.expectEqual(report.pulled, 1, "iCloud 쪽 바깥 편집을 받지 못했다")
        mini.reload()
        t.expectEqual(mini.store.loadDocument(id: meta.id)?.body, "아이폰에서 고침")
        t.expect(try mini.sync.sync().isEmpty, "맴돈다")
    }
}

runner.test("양쪽을 모두 바깥에서 고치면 충돌 사본을 남긴다") { t in
    try MainActor.assumeIsolated {
        let (mini, _, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "처음 내용")
        _ = try mini.sync.sync()

        let now = Date()
        try editOutside(memoFile(mini.root, meta.id), replacing: "처음 내용", with: "맥에서 고침", mtime: now.addingTimeInterval(60))
        try editOutside(memoFile(mini.sync.remoteRoot, meta.id), replacing: "처음 내용", with: "폰에서 고침", mtime: now.addingTimeInterval(120))

        let report = try mini.sync.sync()
        t.expectEqual(report.conflicts, 1, "충돌 사본이 없다")
        mini.reload()
        t.expectEqual(mini.store.summaries.count, 2, "원본과 사본 두 개여야 한다")
        t.expectEqual(mini.store.loadDocument(id: meta.id)?.body, "폰에서 고침", "더 늦게 고친 쪽이 정본이어야 한다")
        let copy = mini.store.summaries.first { $0.meta.conflictOf == meta.id }
        t.expectNotNil(copy, "사본 표시가 없다")
        t.expectEqual(copy.flatMap { mini.store.loadDocument(id: $0.id)?.body }, "맥에서 고침", "진 쪽 내용이 사본에 없다")
    }
}

runner.test("예전 형식 상태 파일은 그대로 읽히고, 다음 동기화부터 지문이 채워진다") { t in
    try MainActor.assumeIsolated {
        let (mini, book, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "처음 내용")
        _ = try mini.sync.sync()
        _ = try book.sync.sync()

        // 상태 파일은 예전과 같은 평면 사전이다. 지문 파일을 없애면 예전 상태와 같다.
        let stateURL = mini.root.appendingPathComponent("sync-state.json")
        let hashesURL = mini.root.appendingPathComponent("sync-state.hashes.json")
        let legacy = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: stateURL))
        t.expectNotNil(legacy[meta.id.rawValue])
        try FileManager.default.removeItem(at: hashesURL)

        t.expect(try mini.sync.sync().isEmpty, "예전 상태에서 바뀐 것이 없는데 움직였다")
        t.expect(FileManager.default.fileExists(atPath: hashesURL.path), "지문이 채워지지 않았다")

        // 예전 방식(modified)으로도 정상 편집은 전파된다.
        try FileManager.default.removeItem(at: hashesURL)
        mini.store.saveBody(id: meta.id, body: "앱에서 고침")
        let report = try mini.sync.sync()
        t.expectEqual(report.pushed, 1, "예전 형식에서 편집이 올라가지 않았다")
        _ = try book.sync.sync()
        book.reload()
        t.expectEqual(book.store.loadDocument(id: meta.id)?.body, "앱에서 고침")
    }
}

runner.test("프론트매터가 깨진 파일은 건너뛰고 세며, 반대쪽 정상 파일을 덮지 않는다") { t in
    try MainActor.assumeIsolated {
        let (mini, _, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "정상 내용")
        _ = try mini.sync.sync()

        // iCloud 쪽 파일이 깨졌다.
        let remoteFile = memoFile(mini.sync.remoteRoot, meta.id)
        try Data("깨진 파일".utf8).write(to: remoteFile)
        // 처음 보는 깨진 메모도 있다.
        let strangeID = MemoID.generate()
        let strangeDirectory = mini.sync.remoteRoot.appendingPathComponent("memos/\(strangeID.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: strangeDirectory, withIntermediateDirectories: true)
        try Data("---\n제대로 닫히지 않음".utf8).write(to: strangeDirectory.appendingPathComponent("memo.md"))

        mini.store.saveBody(id: meta.id, body: "앱에서 고침")
        let report = try mini.sync.sync()
        t.expectEqual(report.unreadable, 2, "읽지 못한 파일 수가 다르다")
        t.expect(report.summary.contains("읽지 못한 파일 2"), "요약에 안 보인다: \(report.summary)")
        t.expectEqual(try String(contentsOf: remoteFile, encoding: .utf8), "깨진 파일", "깨진 파일을 덮어썼다")
        t.expect(!FileManager.default.fileExists(atPath: memoFile(mini.root, strangeID).path), "깨진 파일을 받았다")
    }
}

// MARK: - iPhone 읽기용 사본

runner.test("읽기용 사본: 파일 이름을 정리한다") { t in
    t.expectEqual(ReadableCopy.sanitizeName("a/b\\c:d*e?f\"g<h>i|j\nk", fallback: "x"), "a-b-c-d-e-f-g-h-i-j-k")
    t.expectEqual(ReadableCopy.sanitizeName("  ..제목..  ", fallback: "x"), "제목")
    t.expectEqual(ReadableCopy.sanitizeName("...", fallback: "제목 없는 메모"), "제목 없는 메모")
    t.expectEqual(ReadableCopy.sanitizeName(String(repeating: "가", count: 200), fallback: "x").count, 80)
    var used = Set<String>()
    t.expectEqual(ReadableCopy.uniqueName("메모", used: &used), "메모")
    t.expectEqual(ReadableCopy.uniqueName("메모", used: &used), "메모 (2)")
    t.expectEqual(ReadableCopy.uniqueName("메모", used: &used), "메모 (3)")
    t.expectEqual(ReadableCopy.uniqueName("MEMO", used: &used), "MEMO")
    t.expectEqual(ReadableCopy.uniqueName("memo", used: &used), "memo (2)")
}

runner.test("읽기용 사본: 제목이 본문 첫 줄과 다르면 맨 위에 붙인다") { t in
    t.expectEqual(ReadableCopy.compose(title: "장보기", body: "# 장보기\n- 우유"), "# 장보기\n- 우유")
    t.expectEqual(ReadableCopy.compose(title: "장보기", body: "- 우유"), "# 장보기\n\n- 우유")
}

runner.test("읽기용 사본: 그룹별 폴더, 중복 이름, 이미지 경로와 복사, 휴지통 제외, 오래된 파일 정리") { t in
    try MainActor.assumeIsolated {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReadableTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("local", isDirectory: true)
        let output = base.appendingPathComponent("MDemo 읽기용", isDirectory: true)
        let repository = try FileMemoRepository(rootDirectory: root)

        let first = MemoMeta(id: .generate(), title: "장보기", group: "집", created: Date(timeIntervalSince1970: 1000))
        let second = MemoMeta(id: .generate(), title: "장보기", group: "집", created: Date(timeIntervalSince1970: 2000))
        let loose = MemoMeta(id: .generate(), title: nil, group: nil, created: Date(timeIntervalSince1970: 3000))
        let trashed = MemoMeta(id: .generate(), title: "버린 메모", group: "집", created: Date(timeIntervalSince1970: 4000))
        try repository.save(MemoDocument(meta: first, body: "우유\n\n![사진](attachments/a b.png =260)\n![없음](attachments/none.png)"))
        try repository.save(MemoDocument(meta: second, body: "두 번째"))
        try repository.save(MemoDocument(meta: loose, body: "# 아무 그룹 없음\n본문"))
        try repository.save(MemoDocument(meta: trashed, body: "버림"))
        try repository.moveToTrash(id: trashed.id)

        let attachments = repository.attachmentsDirectory(for: first.id)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: attachments.appendingPathComponent("a b.png"))

        let copy = ReadableCopy(localRoot: root, outputRoot: output)
        let result = try copy.update()
        t.expect(result.written >= 5, "처음에는 모두 써야 한다: \(result)")

        func read(_ path: String) -> String? {
            try? String(contentsOf: output.appendingPathComponent(path), encoding: .utf8)
        }
        let prefix = String(first.id.rawValue.prefix(8))
        let firstText = read("집/장보기.md")
        t.expectNotNil(firstText, "첫 메모가 없다")
        t.expect(firstText?.contains("![사진](첨부/\(prefix)-a%20b.png)") == true, "이미지 경로가 안 고쳐졌다: \(firstText ?? "")")
        t.expect(firstText?.contains("=260") == false, "크기 표기가 남았다")
        t.expect(firstText?.contains("![없음](attachments/none.png)") == true, "없는 그림 줄은 그대로여야 한다")
        t.expect(firstText?.contains("schemaVersion") == false, "프론트매터가 들어갔다")
        t.expectEqual(try Data(contentsOf: output.appendingPathComponent("집/첨부/\(prefix)-a b.png")), Data([1, 2, 3]), "그림이 복사되지 않았다")
        t.expectEqual(read("집/장보기 (2).md"), "# 장보기\n\n두 번째", "중복 이름 처리가 다르다")
        t.expectEqual(read("미분류/아무 그룹 없음.md"), "# 아무 그룹 없음\n본문")
        t.expectNil(read("집/버린 메모.md"), "휴지통 메모가 들어갔다")
        t.expectEqual(read("읽어 주세요.txt")?.hasPrefix("이 폴더는 MDemo가 만드는 읽기용 사본입니다."), true)

        // 같은 내용이면 다시 쓰지 않는다.
        let stampURL = output.appendingPathComponent("집/장보기.md")
        let before = try stampURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        Thread.sleep(forTimeInterval: 0.05)
        let again = try copy.update()
        t.expectEqual(again.written, 0, "내용이 같은데 다시 썼다: \(again)")
        t.expectEqual(again.removed, 0)
        t.expectEqual(try stampURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)

        // 제목을 바꾸고 메모를 지우면 옛 파일이 정리된다. 숨김 파일은 건드리지 않는다.
        try Data("x".utf8).write(to: output.appendingPathComponent("집/.DS_Store"))
        var renamed = first
        renamed.title = "새 제목"
        try repository.save(MemoDocument(meta: renamed, body: "내용"))
        try repository.moveToTrash(id: second.id)
        let cleaned = try copy.update()
        t.expect(cleaned.removed >= 3, "오래된 파일이 안 지워졌다: \(cleaned)")
        t.expectNil(read("집/장보기.md"), "바뀐 제목의 옛 파일이 남았다")
        t.expectNil(read("집/장보기 (2).md"), "지워진 메모의 파일이 남았다")
        t.expectNotNil(read("집/새 제목.md"))
        t.expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("집/첨부").path), "안 쓰는 첨부 폴더가 남았다")
        t.expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("집/.DS_Store").path), "숨김 파일을 지웠다")
    }
}

runner.test("읽기용 사본 설정은 기본이 켬이고 저장하면 다시 읽힌다") { t in
    MainActor.assumeIsolated {
        let suite = "MDemoReadableCopyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppPreferences(store: defaults)
        t.expectEqual(first.readableCopyEnabled, true)
        first.readableCopyEnabled = false
        t.expectEqual(AppPreferences(store: defaults).readableCopyEnabled, false)
    }
}


// MARK: - 동기화 보강 점검 (Codex 검수 7항목)

/// 시험용 읽기용 사본 환경: 메모 하나가 든 로컬 폴더와 출력 폴더.
func makeReadableFixture(body: String = "본문") throws -> (root: URL, output: URL, base: URL, repository: FileMemoRepository, meta: MemoMeta) {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ReadableAudit-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("local", isDirectory: true)
    let output = base.appendingPathComponent("MDemo 읽기용/내 맥", isDirectory: true)
    let repository = try FileMemoRepository(rootDirectory: root)
    let meta = MemoMeta(id: .generate(), title: "제목", group: "집", created: Date(timeIntervalSince1970: 1000))
    try repository.save(MemoDocument(meta: meta, body: body))
    return (root, output, base, repository, meta)
}

runner.test("항목1: 읽기용 정리는 앱이 만든 파일만 지우고 사용자 파일은 둔다") { t in
    try MainActor.assumeIsolated {
        let f = try makeReadableFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let copy = ReadableCopy(localRoot: f.root, outputRoot: f.output)

        // 앱이 만들기 전부터 있던 사용자 파일
        try FileManager.default.createDirectory(at: f.output.appendingPathComponent("집"), withIntermediateDirectories: true)
        let mine = f.output.appendingPathComponent("집/내 문서.md")
        try Data("사용자 파일".utf8).write(to: mine)
        let loose = f.output.appendingPathComponent("사진.jpg")
        try Data([9]).write(to: loose)

        _ = try copy.update()
        t.expect(FileManager.default.fileExists(atPath: f.output.appendingPathComponent("집/제목.md").path), "사본이 없다")
        try f.repository.moveToTrash(id: f.meta.id)
        let result = try copy.update()
        t.expect(!FileManager.default.fileExists(atPath: f.output.appendingPathComponent("집/제목.md").path), "옛 사본이 남았다")
        t.expectEqual(result.removed, 1, "앱이 만든 파일만 지워야 한다: \(result)")
        t.expect(FileManager.default.fileExists(atPath: mine.path), "사용자 파일을 지웠다")
        t.expect(FileManager.default.fileExists(atPath: loose.path), "사용자 파일을 지웠다 (최상위)")
    }
}

runner.test("항목1: 읽기용 사본은 심볼릭 링크 폴더를 지나 밖에 쓰지 않는다") { t in
    try MainActor.assumeIsolated {
        let f = try makeReadableFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let outside = f.base.appendingPathComponent("밖", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("밖의 파일".utf8).write(to: outside.appendingPathComponent("남의 것.md"))
        try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.output.appendingPathComponent("집"), withDestinationURL: outside)

        let copy = ReadableCopy(localRoot: f.root, outputRoot: f.output)
        _ = try copy.update()
        _ = try copy.update()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? []
        t.expectEqual(names, ["남의 것.md"], "링크를 따라 밖에 썼다: \(names)")
        t.expectEqual(try String(contentsOf: outside.appendingPathComponent("남의 것.md"), encoding: .utf8), "밖의 파일")
    }
}

runner.test("항목6: 메모 폴더를 훑지 못하면 정리하지 않고, 읽지 못한 메모의 옛 사본은 둔다") { t in
    try MainActor.assumeIsolated {
        let f = try makeReadableFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let other = MemoMeta(id: .generate(), title: "다른", group: "집", created: Date(timeIntervalSince1970: 2000))
        try f.repository.save(MemoDocument(meta: other, body: "다른 본문"))
        let copy = ReadableCopy(localRoot: f.root, outputRoot: f.output)
        _ = try copy.update()
        let keptFile = f.output.appendingPathComponent("집/제목.md")
        let otherFile = f.output.appendingPathComponent("집/다른.md")
        t.expect(FileManager.default.fileExists(atPath: keptFile.path) && FileManager.default.fileExists(atPath: otherFile.path))

        // 메모 하나가 깨졌다: 그 메모의 옛 사본은 남아야 한다.
        try Data("깨진 파일".utf8).write(to: f.root.appendingPathComponent("memos/\(f.meta.id.rawValue)/memo.md"))
        _ = try copy.update()
        t.expect(FileManager.default.fileExists(atPath: keptFile.path), "읽지 못한 메모의 옛 사본을 지웠다")

        // 메모 폴더 자체를 훑지 못한다.
        try FileManager.default.moveItem(at: f.root.appendingPathComponent("memos"), to: f.base.appendingPathComponent("memos-away"))
        let aborted = try? copy.update()
        t.expect(FileManager.default.fileExists(atPath: keptFile.path), "훑기 실패인데 정리했다")
        t.expect(FileManager.default.fileExists(atPath: otherFile.path), "훑기 실패인데 정리했다 (2)")
        t.expectEqual(aborted?.removed ?? 0, 0)
    }
}

runner.test("항목7: 읽기용 사본은 이 맥 이름의 하위 폴더에 만든다") { t in
    t.expectEqual(ReadableCopy.deviceFolderName(from: "Mac mini.local"), "Mac mini")
    t.expectEqual(ReadableCopy.deviceFolderName(from: "a/b:c"), "a-b-c")
    t.expectEqual(ReadableCopy.deviceFolderName(from: "  "), "이 맥")
    let output = ReadableCopy.defaultOutputRoot(deviceName: "맥미니")
    if let output {
        t.expectEqual(output.lastPathComponent, "맥미니")
        t.expectEqual(output.deletingLastPathComponent().lastPathComponent, ReadableCopy.folderName)
    }
    t.expect(ReadableCopy.noticeText.contains("맥"), "읽어 주세요 문구에 기기별 폴더 설명이 없다")

    // 두 맥이 같은 부모 아래 각자 폴더에 만들어도 서로 지우지 않는다.
    try MainActor.assumeIsolated {
        let f = try makeReadableFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let parent = f.output.deletingLastPathComponent()
        let mini = ReadableCopy(localRoot: f.root, outputRoot: parent.appendingPathComponent("맥미니"))
        _ = try mini.update()
        let emptyRoot = f.base.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot.appendingPathComponent("memos"), withIntermediateDirectories: true)
        let book = ReadableCopy(localRoot: emptyRoot, outputRoot: parent.appendingPathComponent("맥북"))
        _ = try book.update()
        _ = try book.update()
        t.expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("맥미니/집/제목.md").path), "다른 맥의 사본이 지워졌다")
    }
}

runner.test("항목2: 한쪽은 휴지통, 반대쪽은 고쳤으면 고친 쪽을 지우지 않는다") { t in
    try MainActor.assumeIsolated {
        let (mini, _, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "처음 내용")
        _ = try mini.sync.sync()

        // 이 맥에서 버리고, iCloud 쪽(다른 기기)에서 고쳤다.
        mini.store.moveToTrash(id: meta.id)
        try editOutside(memoFile(mini.sync.remoteRoot, meta.id), replacing: "처음 내용", with: "다른 기기에서 고침",
                        mtime: Date().addingTimeInterval(60))
        _ = try mini.sync.sync()

        // 고친 내용이 어딘가 활성 메모로 남아 있어야 한다.
        mini.reload()
        let survivors = mini.store.summaries.compactMap { mini.store.loadDocument(id: $0.id)?.body }
        t.expect(survivors.contains("다른 기기에서 고침"), "고친 내용이 사라졌다: \(survivors)")
        // 반대 방향도 같다: 이 맥에서 고치고 iCloud 쪽에서 버렸다.
        let meta2 = mini.store.createMemo()
        mini.store.saveBody(id: meta2.id, body: "둘째 처음")
        _ = try mini.sync.sync()
        let repo = try FileMemoRepository(rootDirectory: mini.sync.remoteRoot)
        try repo.moveToTrash(id: meta2.id)
        mini.store.saveBody(id: meta2.id, body: "둘째 이 맥에서 고침")
        _ = try mini.sync.sync()
        mini.reload()
        let survivors2 = mini.store.summaries.compactMap { mini.store.loadDocument(id: $0.id)?.body }
        t.expect(survivors2.contains("둘째 이 맥에서 고침"), "이 맥에서 고친 내용이 사라졌다: \(survivors2)")
    }
}

runner.test("항목3: 훑은 뒤 반대쪽이 바뀌었으면 이번엔 덮어쓰지 않고 다음에 맞춘다") { t in
    try MainActor.assumeIsolated {
        let (mini, _, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "처음 내용")
        _ = try mini.sync.sync()

        mini.store.saveBody(id: meta.id, body: "맥에서 고침")
        let remoteFile = memoFile(mini.sync.remoteRoot, meta.id)
        var racing = mini.sync
        racing.afterScan = {
            try? editOutside(remoteFile, replacing: "처음 내용", with: "그 사이 폰에서 고침", mtime: Date().addingTimeInterval(120))
        }
        _ = try racing.sync()
        let during = try String(contentsOf: remoteFile, encoding: .utf8)
        t.expect(during.contains("그 사이 폰에서 고침"), "훑은 뒤 바뀐 파일을 덮어썼다")

        // 다음 동기화에서는 둘 다 보존된다.
        _ = try mini.sync.sync()
        mini.reload()
        let bodies = mini.store.summaries.compactMap { mini.store.loadDocument(id: $0.id)?.body }
        t.expect(bodies.contains("맥에서 고침"), "맥 편집이 사라졌다: \(bodies)")
        t.expect(bodies.contains("그 사이 폰에서 고침"), "폰 편집이 사라졌다: \(bodies)")
    }
}

runner.test("항목4: 충돌 사본에는 진 쪽의 첨부 폴더도 함께 담긴다") { t in
    try MainActor.assumeIsolated {
        let (mini, _, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "처음 내용")
        _ = try mini.sync.sync()

        // 양쪽이 각자 다른 그림을 붙이고 고쳤다. 폰 쪽이 더 늦다.
        let localAttachments = mini.root.appendingPathComponent("memos/\(meta.id.rawValue)/attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: localAttachments, withIntermediateDirectories: true)
        try Data([1, 1]).write(to: localAttachments.appendingPathComponent("mac.png"))
        let remoteAttachments = mini.sync.remoteRoot.appendingPathComponent("memos/\(meta.id.rawValue)/attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteAttachments, withIntermediateDirectories: true)
        try Data([2, 2]).write(to: remoteAttachments.appendingPathComponent("phone.png"))
        let now = Date()
        try editOutside(memoFile(mini.root, meta.id), replacing: "처음 내용", with: "맥 ![](attachments/mac.png)", mtime: now.addingTimeInterval(60))
        try editOutside(memoFile(mini.sync.remoteRoot, meta.id), replacing: "처음 내용", with: "폰 ![](attachments/phone.png)", mtime: now.addingTimeInterval(120))

        let report = try mini.sync.sync()
        t.expectEqual(report.conflicts, 1)
        mini.reload()
        let copy = mini.store.summaries.first { $0.meta.conflictOf == meta.id }
        t.expectNotNil(copy, "사본이 없다")
        if let copy {
            let image = mini.root.appendingPathComponent("memos/\(copy.id.rawValue)/attachments/mac.png")
            t.expectEqual(try? Data(contentsOf: image), Data([1, 1]), "사본에 진 쪽 그림이 없다")
        }
    }
}

runner.test("항목5: 지문이 없을 때 내용이 다르면 같은 상태로 확정하지 않고 둘 다 남긴다") { t in
    try MainActor.assumeIsolated {
        let (mini, _, base) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = mini.store.createMemo()
        mini.store.saveBody(id: meta.id, body: "처음 내용")
        _ = try mini.sync.sync()

        // 상태가 예전 형식(지문 없음)이고, iCloud 쪽 본문만 바깥에서 바뀌었다 (modified는 그대로).
        try FileManager.default.removeItem(at: mini.root.appendingPathComponent("sync-state.hashes.json"))
        try editOutside(memoFile(mini.sync.remoteRoot, meta.id), replacing: "처음 내용", with: "바깥에서 고침", mtime: Date().addingTimeInterval(60))
        _ = try mini.sync.sync()
        mini.reload()
        var bodies = mini.store.summaries.compactMap { mini.store.loadDocument(id: $0.id)?.body }
        t.expect(bodies.contains("바깥에서 고침"), "바깥 편집이 사라졌다: \(bodies)")
        t.expect(bodies.count == 2 || bodies == ["바깥에서 고침"], "예상 밖의 결과: \(bodies)")

        // 상태 파일이 아예 없는 첫 동기화: 같은 ID, 같은 modified, 다른 내용.
        let (a, _, base2) = try makeTwoDevices()
        defer { try? FileManager.default.removeItem(at: base2) }
        let first = a.store.createMemo()
        a.store.saveBody(id: first.id, body: "맥 내용")
        _ = try a.sync.sync()
        try FileManager.default.removeItem(at: a.root.appendingPathComponent("sync-state.json"))
        try? FileManager.default.removeItem(at: a.root.appendingPathComponent("sync-state.hashes.json"))
        try editOutside(memoFile(a.sync.remoteRoot, first.id), replacing: "맥 내용", with: "클라우드 내용", mtime: Date())
        let report = try a.sync.sync()
        t.expectEqual(report.conflicts, 1, "다른 내용인데 충돌 사본을 만들지 않았다")
        a.reload()
        bodies = a.store.summaries.compactMap { a.store.loadDocument(id: $0.id)?.body }
        t.expect(bodies.contains("맥 내용") && bodies.contains("클라우드 내용"), "한쪽 내용이 사라졌다: \(bodies)")
    }
}

runner.finish()
