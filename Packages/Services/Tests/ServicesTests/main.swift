import Foundation
import MemoCore
@testable import Services
import TestKit

let runner = TestRunner(CoreStorage.usesRust ? "Services (Rust)" : "Services (Swift)")

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
        let repository = try FileMemoRepository(rootDirectory: root, keychain: testKeychain)
        self.store = MemoStore(repository: repository, keychain: testKeychain)
        self.sync = SyncService(
            localRoot: root,
            remoteRoot: cloud,
            stateURL: root.appendingPathComponent("sync-state.json"),
            keychain: testKeychain
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

        // 충돌 사본은 같은 회차에 반대쪽에도 올라가, 맥미니가 한 번만 맞춰도 받는다.
        _ = try mini.sync.sync()
        mini.reload()
        let miniCopies = mini.store.summaries.filter { $0.meta.conflictOf == meta.id }
        t.expectEqual(miniCopies.map(\.id), copies.map(\.id), "충돌 사본이 맥미니에 오지 않았다")
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
        let repository = try FileMemoRepository(rootDirectory: dataRoot, keychain: testKeychain)
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let backup = BackupService(dataRoot: dataRoot, keychain: testKeychain)

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
        let repository = try FileMemoRepository(rootDirectory: dataRoot, keychain: testKeychain)
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let backup = BackupService(dataRoot: dataRoot, keychain: testKeychain)

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

    let backup = BackupService(dataRoot: base, keychain: testKeychain)
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

    let backup = BackupService(dataRoot: base, keychain: testKeychain)

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
        let remoteRepository = try FileMemoRepository(rootDirectory: mini.sync.remoteRoot, keychain: testKeychain)
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
        let repo = try FileMemoRepository(rootDirectory: mini.sync.remoteRoot, keychain: testKeychain)
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

final class PrivacyTestKeychain: MemoKeychain, @unchecked Sendable {
    private let mutex = NSLock()
    private var failures: [MemoID: Int] = [:]
    func readFailures(id: MemoID) throws -> Int { mutex.lock(); defer { mutex.unlock() }; return failures[id] ?? 0 }
    func writeFailures(_ count: Int, id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; failures[id] = count }
    private var items: [MemoID: Data] = [:]
    func read(id: MemoID) throws -> Data? { mutex.lock(); defer { mutex.unlock() }; return items[id] }
    func write(_ value: Data, id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; items[id] = value }
    func delete(id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; items[id] = nil; failures[id] = nil }
}

await runner.testAsync("암호 메모는 모든 동기화 모드에서 제외되고 원본 파기는 다른 맥과 휴지통에도 전파된다") { t in
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let local = base.appendingPathComponent("local"), remote = base.appendingPathComponent("cloud"), other = base.appendingPathComponent("other")
    let repository = try FileMemoRepository(rootDirectory: local, keychain: testKeychain)
    let keys = PrivacyTestKeychain()
    let store = MemoStore(repository: repository, keychain: keys)
    let source = store.createMemo().id
    store.saveBody(id: source, body: "원본 평문")
    let original = try repository.load(id: source)
    let sync = SyncService(localRoot: local, remoteRoot: remote, stateURL: local.appendingPathComponent("state.json"), keychain: keys)
    _ = try sync.sync(mode: .push)
    let second = SyncService(localRoot: other, remoteRoot: remote, stateURL: other.appendingPathComponent("state.json"), keychain: PrivacyTestKeychain())
    _ = try second.sync(mode: .pull)
    let otherRepository = try FileMemoRepository(rootDirectory: other, keychain: testKeychain)
    try otherRepository.moveToTrash(id: source)
    let id = try await store.createLockedMemo(password: "1234", moving: source)
    // 예전 휴지통 사본도 정리 대상이다.
    let remoteTrash = remote.appendingPathComponent("trash").appendingPathComponent(source.rawValue)
    try FileManager.default.copyItem(at: remote.appendingPathComponent("memos").appendingPathComponent(source.rawValue), to: remoteTrash)
    for mode in [SyncMode.push, .pull, .both] {
        let report = try sync.sync(mode: mode)
        t.expectEqual(report.lockedLocal, 1)
        t.expect(report.summary.contains("잠긴 메모 1개는 이 맥에만 있습니다"))
        t.expect(!FileManager.default.fileExists(atPath: remote.appendingPathComponent("memos").appendingPathComponent(id.rawValue).path))
    }
    t.expect(!FileManager.default.fileExists(atPath: remoteTrash.path))
    _ = try second.sync(mode: .push)
    t.expectEqual(try otherRepository.loadTrashSummaries().count, 0)
    t.expectNil(try? otherRepository.load(id: source))
    // 파기된 ID를 외부 파일 복사로 다시 심어도 받아들이지 않는다.
    let resurrected = remote.appendingPathComponent("memos").appendingPathComponent(source.rawValue)
    try FileManager.default.createDirectory(at: resurrected, withIntermediateDirectories: true)
    try Data(FrontmatterCodec.encode(original).utf8).write(to: resurrected.appendingPathComponent("memo.md"))
    _ = try sync.sync(mode: .pull)
    t.expect(!FileManager.default.fileExists(atPath: resurrected.path))
    let plain = try store.moveToPlainMemo(id: id)
    _ = try sync.sync(mode: .push)
    t.expectEqual(try FileMemoRepository(rootDirectory: remote, keychain: testKeychain).load(id: plain).body, original.body)
}

await runner.testAsync("로컬 전용 ID의 원격 사본은 덮어 지우고 다른 기기에서는 영구 삭제한다") { t in
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("localonly-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let local = base.appendingPathComponent("local"), remote = base.appendingPathComponent("cloud"), other = base.appendingPathComponent("other")
    let keys = PrivacyTestKeychain()
    let repository = try FileMemoRepository(rootDirectory: local, keychain: testKeychain)
    let store = MemoStore(repository: repository, keychain: keys)
    let id = try await store.createLockedMemo(password: "1234")
    let ordinary = MemoDocument(meta: MemoMeta(id: id), body: "외부에서 되살린 평문")
    try FileMemoRepository(rootDirectory: remote, keychain: testKeychain).save(ordinary)
    let otherRepository = try FileMemoRepository(rootDirectory: other, keychain: testKeychain)
    try otherRepository.save(ordinary)
    try otherRepository.moveToTrash(id: id)
    _ = try SyncService(localRoot: local, remoteRoot: remote, stateURL: local.appendingPathComponent("state"), keychain: keys).sync(mode: .pull)
    let report = try SyncService(localRoot: other, remoteRoot: remote, stateURL: other.appendingPathComponent("state"), keychain: PrivacyTestKeychain()).sync(mode: .push)
    t.expectEqual(report.removedLocalOnly, 1)
    t.expect(report.summary.contains("다른 맥에서 잠근 메모 1개를 이 맥에서 지웠습니다"))
    t.expectEqual(try otherRepository.loadTrashSummaries().count, 0)
    t.expect(try repository.load(id: id).meta.isLocked)
}

await runner.testAsync("백업 ZIP에서 암호 메모를 빼고 파기한 ID 가져오기를 거부한다") { t in
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("backup-lock-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Data")
    let repository = try FileMemoRepository(rootDirectory: root, keychain: testKeychain)
    let keys = PrivacyTestKeychain()
    let store = MemoStore(repository: repository, keychain: keys)
    let ordinary = store.createMemo().id
    store.saveBody(id: ordinary, body: "백업 본문")
    let archive = base.appendingPathComponent("old.zip")
    let backup = BackupService(dataRoot: root, keychain: keys)
    _ = try backup.exportBackup(to: archive)
    let locked = try await store.createLockedMemo(password: "1234")
    let filtered = base.appendingPathComponent("filtered.zip")
    t.expectEqual(try backup.exportBackup(to: filtered), 1)
    let destination = base.appendingPathComponent("restored")
    _ = try BackupService(dataRoot: destination, keychain: PrivacyTestKeychain()).importBackup(from: filtered, replaceExisting: false)
    t.expectNil(try? FileMemoRepository(rootDirectory: destination, keychain: testKeychain).load(id: locked))
    try store.destroyMemo(id: ordinary)
    t.expectEqual(try backup.importBackup(from: archive, replaceExisting: false), 1)
    t.expectNil(try? repository.load(id: ordinary))
    // 통째로 교체해도 이 맥에서 만든 암호 메모와 열쇠는 유지한다.
    _ = try backup.importBackup(from: archive, replaceExisting: true)
    t.expect(try repository.load(id: locked).meta.isLocked)
    t.expectNotNil(try keys.read(id: locked))
}

runner.test("장부의 손상 메모는 백업에서 제외한다") { t in
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-corrupt-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Data")
    let repository = try FileMemoRepository(rootDirectory: root, keychain: testKeychain)
    for name in ["destroyed", "local-only"] {
        let id = MemoID.generate()
        try repository.save(MemoDocument(meta: MemoMeta(id: id), body: "제거 대상 " + name))
        try MemoPrivacyLedger.insert(id, name: name, root: root)
        let file = root.appendingPathComponent("memos").appendingPathComponent(id.rawValue).appendingPathComponent("memo.md")
        try Data("손상".utf8).write(to: file)
    }
    let damaged = MemoID.generate()
    let folder = root.appendingPathComponent("memos").appendingPathComponent(damaged.rawValue)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("손상".utf8).write(to: folder.appendingPathComponent("memo.md"))
    let archive = base.appendingPathComponent("backup.zip")
    t.expectEqual(try BackupService(dataRoot: root, keychain: testKeychain).exportBackup(to: archive), 3)
    let restored = base.appendingPathComponent("restored")
    _ = try BackupService(dataRoot: restored, keychain: PrivacyTestKeychain()).importBackup(from: archive, replaceExisting: false)
    t.expectEqual(try FileMemoRepository(rootDirectory: restored, keychain: testKeychain).loadSummaries().count, 0)
}

// MARK: - 구글 드라이브 동기화 (가짜 드라이브 · 임시 폴더 · 메모리 키체인, 실제 네트워크 없음)


struct DriveRig {
    let base: URL
    let local: URL
    let mirror: URL
    let drive = FakeDrive()
    let keys: PrivacyTestKeychain
    let store: MemoStore
    let sync: DriveMirrorSync

    @MainActor
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("drive-" + UUID().uuidString)
        local = base.appendingPathComponent("Data")
        mirror = base.appendingPathComponent("GoogleDrive/MDemo")
        keys = PrivacyTestKeychain()
        store = MemoStore(repository: try FileMemoRepository(rootDirectory: local, keychain: testKeychain), keychain: keys)
        sync = DriveMirrorSync(
            localRoot: local,
            mirrorRoot: mirror,
            driveStateURL: base.appendingPathComponent("GoogleDrive/drive-state.json"),
            engineStateURL: base.appendingPathComponent("sync-state-google.json"),
            api: drive,
            keychain: keys
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
    var stateData: Data? { try? Data(contentsOf: base.appendingPathComponent("GoogleDrive/drive-state.json")) }
    func memoText(_ id: MemoID) -> String? { try? String(contentsOf: mirror.appendingPathComponent("memos/\(id.rawValue)/memo.md"), encoding: .utf8) }
}

runner.test("PKCE: 검증값 길이 · 문자, S256 challenge, 인증 주소 매개변수") { t in
    let verifier = PKCE.makeVerifier()
    t.expect((43...128).contains(verifier.count), "검증값 길이")
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    t.expect(verifier.allSatisfy(allowed.contains), "허용되지 않은 문자")
    t.expect(PKCE.makeVerifier() != verifier, "무작위가 아니다")
    // RFC 7636 부록 B의 예시 값
    t.expectEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let url = PKCE.authorizationURL(clientID: "cid", redirectURI: "http://127.0.0.1:5555", challenge: "chal", state: "st")
    let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    t.expectEqual(url.host, "accounts.google.com")
    t.expectEqual(items["scope"], "https://www.googleapis.com/auth/drive.file openid email")
    t.expectEqual(items["redirect_uri"], "http://127.0.0.1:5555")
    t.expectEqual(items["access_type"], "offline")
    t.expectEqual(items["prompt"], "consent")
    t.expectEqual(items["state"], "st")
    t.expectEqual(items["code_challenge_method"], "S256")
    t.expectEqual(items["response_type"], "code")
}

// MainActor에서만 완료되는 API를 사용해 콜백 대기가 메인 실행기를 점유하지 않는지 확인한다.
await runner.testAsync("Rust 드라이브 콜백은 MainActor 비동기 API를 기다려도 교착하지 않는다") { t in
    let rig = try DriveRig()
    defer { rig.cleanup() }
    let sync = DriveMirrorSync(localRoot: rig.local, mirrorRoot: rig.mirror,
        driveStateURL: rig.base.appendingPathComponent("drive-state.json"),
        engineStateURL: rig.base.appendingPathComponent("engine-state.json"),
        api: MainActorDrive(rig.drive), keychain: rig.keys)
    let id = rig.store.createMemo().id
    rig.store.saveBody(id: id, body: "메인 실행기가 응답한다")
    _ = try await sync.sync()
    t.expect(rig.drive.paths().contains("memos/\(id.rawValue)/memo.md"))
    _ = try await sync.enforcePrivacy()
}

await runner.testAsync("드라이브 첫 동기화는 합치기만 한다: 양쪽 메모가 모두 남고 삭제는 0건") { t in
    let rig = try DriveRig()
    defer { rig.cleanup() }
    let mine = rig.store.createMemo().id
    rig.store.saveBody(id: mine, body: "내 메모")

    // 다른 기기가 드라이브에 둔 메모
    let other = rig.base.appendingPathComponent("other")
    let otherID = MemoID.generate()
    try FileMemoRepository(rootDirectory: other, keychain: testKeychain).save(MemoDocument(meta: MemoMeta(id: otherID), body: "드라이브 메모"))
    rig.drive.put(path: "memos/\(otherID.rawValue)/memo.md", data: try Data(contentsOf: other.appendingPathComponent("memos/\(otherID.rawValue)/memo.md")))

    _ = try await rig.sync.sync()
    t.expect(rig.drive.paths().contains("memos/\(mine.rawValue)/memo.md"), "로컬 메모가 올라가지 않았다")
    rig.store.reloadSummaries()
    t.expect(rig.store.summaries.contains { $0.id == otherID }, "드라이브 메모가 내려오지 않았다")
    t.expect(rig.drive.deletedPaths.isEmpty, "첫 동기화에서 지웠다")
    t.expectEqual(rig.store.summaries.count, 2)
}

await runner.testAsync("원격 변경은 내려받고 로컬 변경은 올리고 양쪽 변경은 충돌 사본을 만든다") { t in
    let rig = try DriveRig()
    defer { rig.cleanup() }
    let id = rig.store.createMemo().id
    rig.store.saveBody(id: id, body: "처음 내용")
    _ = try await rig.sync.sync()
    let path = "memos/\(id.rawValue)/memo.md"

    // 원격만 바뀜
    let original = String(data: rig.drive.data(at: path) ?? Data(), encoding: .utf8) ?? ""
    rig.drive.put(path: path, data: Data(original.replacingOccurrences(of: "처음 내용", with: "원격 내용").utf8))
    _ = try await rig.sync.sync()
    rig.store.reloadSummaries()
    t.expectEqual(rig.store.loadDocument(id: id)?.body, "원격 내용", "내려받지 못했다")

    // 로컬만 바뀜
    rig.store.saveBody(id: id, body: "로컬 내용")
    _ = try await rig.sync.sync()
    t.expect(String(data: rig.drive.data(at: path) ?? Data(), encoding: .utf8)?.contains("로컬 내용") == true, "올리지 못했다")

    // 양쪽 다 바뀜
    rig.store.saveBody(id: id, body: "로컬 둘째")
    let current = String(data: rig.drive.data(at: path) ?? Data(), encoding: .utf8) ?? ""
    rig.drive.put(path: path, data: Data(current.replacingOccurrences(of: "로컬 내용", with: "원격 둘째").utf8))
    let report = try await rig.sync.sync()
    t.expectEqual(report.conflicts, 1, "충돌 사본이 없다")
    for copy in report.conflictCopies {
        t.expect(rig.drive.paths().contains("memos/\(copy.rawValue)/memo.md"), "같은 회차에 충돌 사본을 올려야 한다")
    }
    t.expectEqual(report.conflictCopies.count, 1)
    rig.store.reloadSummaries()
    t.expectEqual(rig.store.summaries.filter { $0.meta.conflictOf != nil }.count, 1)
}

await runner.testAsync("로컬에서 지운 메모는 드라이브에서 영구 삭제(delete)로만 사라진다") { t in
    let rig = try DriveRig()
    defer { rig.cleanup() }
    let id = rig.store.createMemo().id
    rig.store.saveBody(id: id, body: "버릴 메모")
    _ = try await rig.sync.sync()
    rig.store.moveToTrash(id: id)
    _ = try await rig.sync.sync()
    t.expect(rig.drive.deletedPaths.contains("memos/\(id.rawValue)/memo.md"), "영구 삭제가 호출되지 않았다")
    t.expect(rig.drive.paths().contains("trash/\(id.rawValue)/memo.md"), "휴지통 폴더 사본이 올라가야 한다")
    t.expect(!rig.drive.paths().contains("memos/\(id.rawValue)/memo.md"))
    t.expect(rig.drive.calls.allSatisfy { ["list", "download", "upload", "update", "createFolder", "delete"].contains($0) }, "휴지통 호출이 있다")
}

await runner.testAsync("목록 또는 내려받기가 실패하면 아무것도 지우지 않고 상태도 그대로다") { t in
    let rig = try DriveRig()
    defer { rig.cleanup() }
    let first = rig.store.createMemo().id
    let second = rig.store.createMemo().id
    rig.store.saveBody(id: first, body: "하나")
    rig.store.saveBody(id: second, body: "둘")
    _ = try await rig.sync.sync()
    let deletesBefore = rig.drive.deletedPaths.count
    let stateBefore = rig.stateData

    // 한쪽은 원격에서 사라졌고, 다른 쪽은 원격에서 바뀐 상황
    let changedPath = "memos/\(second.rawValue)/memo.md"
    let text = String(data: rig.drive.data(at: changedPath) ?? Data(), encoding: .utf8) ?? ""
    rig.drive.removeRemotely(path: "memos/\(first.rawValue)/memo.md")
    rig.drive.put(path: changedPath, data: Data(text.replacingOccurrences(of: "둘", with: "원격 둘").utf8))

    for mode in ["list", "download"] {
        rig.drive.failList = mode == "list"
        rig.drive.failDownload = mode == "download"
        var failed = false
        do { _ = try await rig.sync.sync() } catch { failed = true }
        t.expect(failed, "\(mode) 실패가 전파되지 않았다")
        t.expectEqual(rig.drive.deletedPaths.count, deletesBefore, "\(mode): 드라이브에서 지웠다")
        t.expect(rig.memoText(first) != nil, "\(mode): 거울에서 지웠다")
        t.expect(rig.memoText(second)?.contains("원격 둘") == false, "\(mode): 거울이 바뀌었다")
        t.expectEqual(rig.stateData, stateBefore, "\(mode): 상태 파일이 바뀌었다")
    }
    rig.store.reloadSummaries()
    t.expectEqual(rig.store.summaries.count, 2, "로컬 메모가 사라졌다")
}

await runner.testAsync("잠긴 메모와 이 기기 전용 장부 메모는 업로드 요청에 한 번도 나오지 않는다") { t in
    let rig = try DriveRig()
    defer { rig.cleanup() }
    let ordinary = rig.store.createMemo().id
    rig.store.saveBody(id: ordinary, body: "보통 메모")
    let locked = try await rig.store.createLockedMemo(password: "1234")
    let ledgerOnly = rig.store.createMemo().id
    rig.store.saveBody(id: ledgerOnly, body: "장부 메모")
    try MemoPrivacyLedger.insert(ledgerOnly, name: "local-only", root: rig.local)
    _ = try await rig.sync.sync()
    _ = try await rig.sync.sync()
    t.expect(rig.drive.uploadedPaths.contains("memos/\(ordinary.rawValue)/memo.md"), "보통 메모는 올라가야 한다")
    for hidden in [locked, ledgerOnly] {
        t.expect(!rig.drive.uploadedPaths.contains { $0.contains(hidden.rawValue) }, "\(hidden.rawValue) 가 업로드 요청에 나왔다")
        t.expect(!rig.drive.paths().contains { $0.contains(hidden.rawValue) }, "\(hidden.rawValue) 가 드라이브에 있다")
    }
}

await runner.testAsync("파기한 메모는 다음 동기화에서 드라이브 파일이 영구 삭제된다") { t in
    let rig = try DriveRig()
    defer { rig.cleanup() }
    let id = rig.store.createMemo().id
    rig.store.saveBody(id: id, body: "파기할 메모")
    _ = try await rig.sync.sync()
    t.expect(rig.drive.paths().contains("memos/\(id.rawValue)/memo.md"))
    try rig.store.destroyMemo(id: id)
    _ = try await rig.sync.sync()
    t.expect(rig.drive.deletedPaths.contains("memos/\(id.rawValue)/memo.md"), "영구 삭제가 호출되지 않았다")
    t.expect(!rig.drive.paths().contains { $0.contains(id.rawValue) && $0.hasSuffix("memo.md") }, "드라이브에 남아 있다")

    // 개인정보 정리만 돌려도 드라이브에서 지워진다.
    let second = rig.store.createMemo().id
    rig.store.saveBody(id: second, body: "두 번째")
    _ = try await rig.sync.sync()
    try rig.store.destroyMemo(id: second)
    _ = try await rig.sync.enforcePrivacy()
    t.expect(!rig.drive.paths().contains { $0.contains(second.rawValue) && $0.hasSuffix("memo.md") }, "정리 직후 드라이브에 남아 있다")
}

/// 메모리 토큰 저장소.
final class MemoryGoogleTokenStore: GoogleTokenStore, @unchecked Sendable {
    private let mutex = NSLock()
    private var credentials: GoogleCredentials?
    func load() throws -> GoogleCredentials? { mutex.lock(); defer { mutex.unlock() }; return credentials }
    func save(_ value: GoogleCredentials) throws { mutex.lock(); defer { mutex.unlock() }; credentials = value }
    func delete() throws { mutex.lock(); defer { mutex.unlock() }; credentials = nil }
}

/// 요청을 기록하고 미리 정한 응답을 돌려주는 가짜 통신.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let mutex = NSLock()
    private(set) var requests: [URLRequest] = []
    private let handler: @Sendable (Int, URLRequest) throws -> HTTPResult
    init(_ handler: @escaping @Sendable (Int, URLRequest) throws -> HTTPResult) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let index = mutex.withLock { () -> Int in requests.append(request); return requests.count }
        return try handler(index, request)
    }
}

final class FixedTokens: AccessTokenProvider, @unchecked Sendable {
    private let mutex = NSLock()
    private(set) var forced: [Bool] = []
    func accessToken(forceRefresh: Bool) async throws -> String {
        mutex.withLock { forced.append(forceRefresh) }
        return forceRefresh ? "새토큰" : "옛토큰"
    }
}

final class SleepLog: @unchecked Sendable {
    private let mutex = NSLock()
    private(set) var seconds: [TimeInterval] = []
    func add(_ value: TimeInterval) { mutex.lock(); seconds.append(value); mutex.unlock() }
}

await runner.testAsync("토큰 저장소: 저장 · 읽기 · 로그아웃 삭제와 폐기 요청") { t in
    let store = MemoryGoogleTokenStore()
    t.expectNil(try store.load())
    try store.save(GoogleCredentials(email: "a@example.com", refreshToken: "refresh-1"))
    t.expectEqual(try store.load(), GoogleCredentials(email: "a@example.com", refreshToken: "refresh-1"))

    let transport = ScriptedTransport { _, request in
        if request.url?.absoluteString.contains("/token") == true {
            return HTTPResult(status: 200, data: Data(#"{"access_token":"access-1","expires_in":3600}"#.utf8))
        }
        throw URLError(.notConnectedToInternet)  // 폐기 요청은 실패해도 로그아웃은 진행해야 한다
    }
    let session = GoogleSession(config: GoogleOAuthConfig(clientID: "cid", clientSecret: "secret"), store: store, transport: transport)
    t.expectEqual(try await session.accessToken(forceRefresh: false), "access-1")
    _ = try await session.accessToken(forceRefresh: false)
    t.expectEqual(transport.requests.count, 1, "만료 전에는 다시 받지 않아야 한다")
    try await session.signOut()
    t.expectNil(try store.load(), "키체인 항목이 남았다")
    t.expect(transport.requests.contains { $0.url?.absoluteString.contains("revoke") == true }, "폐기 요청이 없다")
    var rejected = false
    do { _ = try await session.accessToken(forceRefresh: false) } catch { rejected = true }
    t.expect(rejected, "로그아웃 뒤에도 토큰을 받았다")
}

await runner.testAsync("401은 토큰을 갱신해 한 번만 다시 보내고 429는 백오프로 횟수 제한 안에서 다시 보낸다") { t in
    // 401 한 번 뒤 성공
    let tokens = FixedTokens()
    let sleeps = SleepLog()
    let transport = ScriptedTransport { index, _ in
        index == 1 ? HTTPResult(status: 401, data: Data()) : HTTPResult(status: 200, data: Data(#"{"files":[{"id":"1","name":"MDemo","mimeType":"application/vnd.google-apps.folder"}]}"#.utf8))
    }
    let client = GoogleDriveClient(tokens: tokens, transport: transport, sleep: { sleeps.add($0) })
    let files = try await client.list()
    t.expectEqual(files.count, 1)
    t.expectEqual(tokens.forced, [false, true], "401 뒤 갱신하지 않았다")
    t.expectEqual(transport.requests.count, 2)
    t.expect(transport.requests[0].url?.absoluteString.contains("trashed") == true, "휴지통 제외 조건이 없다")

    // 계속 401이면 두 번에서 멈춘다
    let always401 = ScriptedTransport { _, _ in HTTPResult(status: 401, data: Data()) }
    var failed = false
    do { _ = try await GoogleDriveClient(tokens: FixedTokens(), transport: always401, sleep: { _ in }).list() } catch { failed = true }
    t.expect(failed)
    t.expectEqual(always401.requests.count, 2, "401 재시도는 1번뿐이어야 한다")

    // 429는 최대 5번 다시 보낸다 (처음 1 + 재시도 5)
    let throttled = ScriptedTransport { _, _ in HTTPResult(status: 429, data: Data()) }
    let throttledSleeps = SleepLog()
    failed = false
    do { _ = try await GoogleDriveClient(tokens: FixedTokens(), transport: throttled, sleep: { throttledSleeps.add($0) }).list() } catch { failed = true }
    t.expect(failed)
    t.expectEqual(throttled.requests.count, 6, "재시도 횟수 제한")
    t.expectEqual(throttledSleeps.seconds.count, 5)
    t.expect(zip(throttledSleeps.seconds, throttledSleeps.seconds.dropFirst()).allSatisfy { $0 < $1 }, "지수 백오프로 늘어나야 한다")

    // 삭제는 DELETE 요청 하나, 휴지통 경로 없음
    let ok = ScriptedTransport { _, _ in HTTPResult(status: 204, data: Data()) }
    try await GoogleDriveClient(tokens: FixedTokens(), transport: ok, sleep: { _ in }).delete(id: "abc")
    t.expectEqual(ok.requests.first?.httpMethod, "DELETE")
    t.expect(ok.requests.first?.url?.absoluteString.contains("trash") == false)
}


// MARK: - 노션 올리기

final class MemoryNotionTokenStore: NotionTokenStore, @unchecked Sendable {
    private let mutex = NSLock()
    private var credentials: NotionCredentials?
    func load() throws -> NotionCredentials? { mutex.lock(); defer { mutex.unlock() }; return credentials }
    func save(_ value: NotionCredentials) throws { mutex.lock(); defer { mutex.unlock() }; credentials = value }
    func delete() throws { mutex.lock(); defer { mutex.unlock() }; credentials = nil }
}

/// 호출을 기록만 하는 가짜 노션. 잠긴 메모에서 호출이 0건인지 확인하는 데 쓴다.
final class FakeNotionAPI: NotionAPI, @unchecked Sendable {
    private let mutex = NSLock()
    private(set) var calls: [String] = []
    var pageExists = true
    private var counter = 0
    private func record(_ call: String) { mutex.lock(); calls.append(call); mutex.unlock() }
    private func nextID() -> String { mutex.lock(); defer { mutex.unlock() }; counter += 1; return "page-\(counter)" }
    func search(query: String) async throws -> [NotionSearchItem] { record("search"); return [] }
    func titlePropertyName(databaseID: String) async throws -> String { record("titleProperty"); return "이름" }
    func createPage(target: NotionTarget, titleProperty: String?, title: String) async throws -> NotionPage {
        record("create:\(target.type.rawValue):\(titleProperty ?? "-"):\(title)")
        let id = nextID()
        return NotionPage(id: id, url: "https://notion.so/\(id)")
    }
    func existingPage(id: String) async throws -> NotionPage? {
        record("existing:\(id)")
        return pageExists ? NotionPage(id: id, url: "https://notion.so/\(id)") : nil
    }
    func updateTitle(pageID: String, titleProperty: String, title: String) async throws { record("title:\(pageID):\(title)") }
    func clearChildren(pageID: String) async throws { record("clear:\(pageID)") }
    func append(pageID: String, blocks: [NotionBlock], uploadedImages: [String: String]) async throws { record("append:\(pageID):\(blocks.count)") }
    func uploadImage(data: Data, fileName: String) async throws -> String { record("image:\(fileName)"); return "file-1" }
}

let notionConfig = NotionOAuthConfig(clientID: "cid", relayURL: "https://relay.example.com/")

runner.test("노션 인증 주소와 state 형식, 다른 state나 경로는 거부한다") { t in
    let state = NotionAuth.makeState(port: 51234)
    let parts = state.split(separator: ".", maxSplits: 1).map(String.init)
    t.expectEqual(parts.first, "51234")
    t.expectEqual(parts.last?.count, 32, "무작위 부분은 32자")
    t.expect(parts.last?.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } == true, "base64url 문자만")
    t.expect(NotionAuth.makeState(port: 51234) != state, "매번 달라야 한다")

    let url = NotionAuth.authorizationURL(config: notionConfig, state: state)
    let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    t.expect(url.absoluteString.hasPrefix("https://api.notion.com/v1/oauth/authorize?"))
    t.expectEqual(items["client_id"], "cid")
    t.expectEqual(items["response_type"], "code")
    t.expectEqual(items["owner"], "user")
    t.expectEqual(items["redirect_uri"], "https://relay.example.com/api/notion/callback")
    t.expectEqual(items["state"], state)

    t.expectEqual(try NotionAuth.code(fromCallback: ["code": "abc", "state": state], path: "/notion", expectedState: state), "abc")
    for (query, path) in [(["code": "abc", "state": "other"], "/notion"), (["code": "abc"], "/notion"), (["code": "abc", "state": state], "/other")] {
        var rejected = false
        do { _ = try NotionAuth.code(fromCallback: query, path: path, expectedState: state) } catch NotionAuthError.stateMismatch { rejected = true }
        t.expect(rejected, "state나 경로가 다른데 받아들였다")
    }
    t.expectEqual(LoopbackReceiver.parsePath(fromRequest: "GET /notion?code=1&state=2 HTTP/1.1\r\nHost: x"), "/notion")
}

runner.test("마크다운을 노션 블록으로 바꾼다 (제목 · 중첩 목록 · 체크 · 인용 · 코드 · 구분선 · 표 · 굵게 · 링크)") { t in
    let markdown = """
    # 큰 제목
    ## 중간
    본문 **굵게** 와 *기울임* ~~취소~~ `코드` [노션](https://notion.so)
    - 하나
      - 둘
        - 셋
          - 넷
    1. 번호
    - [x] 완료
    - [ ] 할 일
    > 인용 첫 줄
    > 인용 둘째 줄
    ---
    ```swift
    let a = 1
    ```
    ```nope
    x
    ```
    | 이름 | 값 |
    | --- | --- |
    | a | **b** |
    <span style="color:#D44C47">빨강</span> ==형광==
    """
    let blocks = NotionBlocks.from(markdown: markdown)
    t.expectEqual(blocks[0].kind, .heading(1))
    t.expectEqual(blocks[1].kind, .heading(2))
    let paragraph = blocks[2].richText
    t.expect(paragraph.contains { $0.text == "굵게" && $0.bold }, "굵게")
    t.expect(paragraph.contains { $0.text == "기울임" && $0.italic }, "기울임")
    t.expect(paragraph.contains { $0.text == "취소" && $0.strikethrough }, "취소선")
    t.expect(paragraph.contains { $0.text == "코드" && $0.code }, "인라인 코드")
    t.expect(paragraph.contains { $0.text == "노션" && $0.link == "https://notion.so" }, "링크")
    // 목록 중첩: 하나 > 둘 > 셋 (넷은 한도를 넘어 셋과 같은 단계)
    t.expectEqual(blocks[3].kind, .bulleted)
    t.expectEqual(blocks[3].children.count, 1)
    t.expectEqual(blocks[3].children[0].children.count, 2, "중첩 2단계를 넘는 항목은 같은 단계에 둔다")
    t.expectEqual(blocks[4].kind, .numbered)
    t.expectEqual(blocks[5].kind, .todo(checked: true))
    t.expectEqual(blocks[6].kind, .todo(checked: false))
    t.expectEqual(blocks[7].kind, .quote)
    t.expectEqual(blocks[7].richText.map(\.text).joined(), "인용 첫 줄\n인용 둘째 줄")
    t.expectEqual(blocks[8].kind, .divider)
    t.expectEqual(blocks[9].kind, .code(language: "swift"))
    t.expectEqual(blocks[9].richText.first?.text, "let a = 1")
    t.expectEqual(blocks[10].kind, .code(language: "plain text"), "모르는 언어")
    t.expectEqual(blocks[11].kind, .table)
    t.expectEqual(blocks[11].rows.count, 2)
    t.expect(blocks[11].rows[1][1].first?.bold == true, "칸 안의 굵게")
    t.expectEqual(blocks[12].richText.first?.color, "red", "글자 색")
    t.expectEqual(blocks[12].richText.last?.color, "yellow_background", "형광펜")

    // JSON 모양
    let json = blocks[11].json()
    t.expectEqual(json["type"] as? String, "table")
    t.expectEqual((json["table"] as? [String: Any])?["table_width"] as? Int, 2)
    t.expectEqual(blocks[5].json()["type"] as? String, "to_do")
    let image = NotionBlock(.image(path: "attachments/a.png", alt: ""))
    t.expectEqual(image.json()["type"] as? String, "paragraph", "올리지 못한 이미지는 문단")
    t.expectEqual(image.json(uploadedImages: ["attachments/a.png": "f1"])["type"] as? String, "image")

    // 2000자 분할 (UTF-16 기준)
    let long = String(repeating: "가", count: 4500)
    let split = NotionBlocks.from(markdown: long)[0].richText
    t.expectEqual(split.map(\.text.count), [2000, 2000, 500])
    t.expectEqual(split.map(\.text).joined(), long)
    let emoji = NotionBlocks.from(markdown: String(repeating: "😀", count: 1500))[0].richText
    t.expect(emoji.allSatisfy { $0.text.utf16.count <= 2000 }, "이모지도 2000(UTF-16)을 넘지 않는다")

    // 100블록 묶음 분할
    let many = NotionBlocks.from(markdown: (1...250).map { "문단 \($0)" }.joined(separator: "\n"))
    t.expectEqual(many.count, 250)
    t.expectEqual(NotionBlocks.chunks(many).map(\.count), [100, 100, 50])
}

await runner.testAsync("노션 올릴 곳: 페이지면 parent page_id, 데이터베이스면 database_id와 제목 속성 이름") { t in
    let transport = ScriptedTransport { _, request in
        let path = request.url?.path ?? ""
        if path.hasSuffix("/databases/db1") {
            return HTTPResult(status: 200, data: Data(#"{"properties":{"상태":{"type":"select"},"이름":{"type":"title"}}}"#.utf8))
        }
        return HTTPResult(status: 200, data: Data(#"{"id":"new-page","url":"https://notion.so/new-page"}"#.utf8))
    }
    let client = NotionClient(tokens: FixedTokens(), transport: transport, sleep: { _ in })
    func body(_ index: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: transport.requests[index].httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    _ = try await client.createPage(target: NotionTarget(type: .page, id: "p1", title: "상위"), titleProperty: nil, title: "메모")
    let pageParent = body(0)["parent"] as? [String: Any]
    t.expectEqual(pageParent?["page_id"] as? String, "p1")
    t.expectNil(pageParent?["database_id"])
    t.expectNotNil((body(0)["properties"] as? [String: Any])?["title"], "페이지 아래는 title 속성")
    t.expectEqual(transport.requests[0].value(forHTTPHeaderField: "Notion-Version"), "2022-06-28")
    t.expectEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer 옛토큰")

    let property = try await client.titlePropertyName(databaseID: "db1")
    t.expectEqual(property, "이름")
    _ = try await client.createPage(target: NotionTarget(type: .database, id: "db1", title: "표"), titleProperty: property, title: "메모")
    let databaseParent = body(2)["parent"] as? [String: Any]
    t.expectEqual(databaseParent?["database_id"] as? String, "db1")
    t.expectNotNil((body(2)["properties"] as? [String: Any])?["이름"], "제목 속성 이름으로 제목을 넣는다")
}

/// 업로더 시험용 환경: 임시 데이터 폴더(장부)와 연결 기록, 가짜 노션.
struct NotionRig {
    let root: URL
    let api = FakeNotionAPI()
    let links: NotionLinkStore
    let documents: [MemoID: MemoDocument]
    var uploader: NotionUploader {
        let documents = documents
        return NotionUploader(api: api, links: links, root: root, load: { id in
            documents[id].map { NotionMemo(document: $0, title: $0.meta.title ?? "", attachmentsDirectory: URL(fileURLWithPath: "/nonexistent")) }
        })
    }
    init(_ documents: [MemoDocument]) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("notion-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        links = NotionLinkStore(fileURL: root.appendingPathComponent("links/notion-links.json"))
        self.documents = Dictionary(uniqueKeysWithValues: documents.map { ($0.meta.id, $0) })
    }
}

let pageTarget = NotionTarget(type: .page, id: "parent-1", title: "상위")

await runner.testAsync("노션 올리기: 잠긴 · local-only · destroyed 메모는 거부하고 가짜 API 호출 0건") { t in
    let locked = MemoDocument(meta: MemoMeta(id: .generate(), title: "잠김", isLocked: true), body: "비밀")
    let localOnly = MemoDocument(meta: MemoMeta(id: .generate(), title: "이 기기만"), body: "비밀")
    let destroyed = MemoDocument(meta: MemoMeta(id: .generate(), title: "파기"), body: "비밀")
    let rig = NotionRig([locked, localOnly, destroyed])
    defer { try? FileManager.default.removeItem(at: rig.root) }
    try MemoPrivacyLedger.insert(localOnly.meta.id, name: "local-only", root: rig.root)
    try MemoPrivacyLedger.insert(destroyed.meta.id, name: "destroyed", root: rig.root)

    for target in [pageTarget, NotionTarget(type: .database, id: "db1", title: "표")] {
        let result = await rig.uploader.upload(ids: [locked.meta.id, localOnly.meta.id, destroyed.meta.id], target: target)
        t.expectEqual(result.excluded, 3)
        t.expect(result.uploaded.isEmpty && result.failures.isEmpty)
    }
    t.expectEqual(rig.api.calls, [], "노션 API가 호출되었다")
    t.expect(!NotionUploader.isUploadAllowed(id: locked.meta.id, isLocked: true, root: rig.root))
    t.expect(!NotionUploader.isUploadAllowed(id: localOnly.meta.id, isLocked: false, root: rig.root))

    // 섞인 선택: 나머지만 올라가고 제외 개수를 돌려준다.
    let plain = MemoDocument(meta: MemoMeta(id: .generate(), title: "일반"), body: "# 안녕\n본문")
    let mixed = NotionRig([locked, plain])
    defer { try? FileManager.default.removeItem(at: mixed.root) }
    let result = await mixed.uploader.upload(ids: [locked.meta.id, plain.meta.id], target: pageTarget)
    t.expectEqual(result.excluded, 1)
    t.expectEqual(result.uploaded.map(\.id), [plain.meta.id])
    t.expectEqual(mixed.api.calls, ["create:page:title:일반", "append:page-1:2"])
    t.expect(!mixed.api.calls.contains { $0.contains("잠김") || $0.contains("비밀") })
}

await runner.testAsync("노션 다시 올리기: 같은 페이지 갱신(블록 삭제 후 추가), 지워졌으면 새로 만들고 올릴 곳이 바뀌면 새 곳에 만든다") { t in
    let memo = MemoDocument(meta: MemoMeta(id: .generate(), title: "제목"), body: "내용")
    let rig = NotionRig([memo])
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let id = memo.meta.id

    _ = await rig.uploader.upload(ids: [id], target: pageTarget)
    t.expectEqual(rig.links.link(for: id)?.pageID, "page-1")

    let again = await rig.uploader.upload(ids: [id], target: pageTarget)
    t.expectEqual(Array(rig.api.calls.dropFirst(2)), ["existing:page-1", "title:page-1:제목", "clear:page-1", "append:page-1:1"])
    t.expectEqual(again.uploaded.first?.url, "https://notion.so/page-1")

    // 페이지가 지워졌다
    rig.api.pageExists = false
    let before = rig.api.calls.count
    _ = await rig.uploader.upload(ids: [id], target: pageTarget)
    t.expectEqual(Array(rig.api.calls.dropFirst(before)), ["existing:page-1", "create:page:title:제목", "append:page-2:1"])
    t.expectEqual(rig.links.link(for: id)?.pageID, "page-2")

    // 올릴 곳이 바뀜: 기존 페이지는 건드리지 않고 새로 만든다
    rig.api.pageExists = true
    let beforeMove = rig.api.calls.count
    _ = await rig.uploader.upload(ids: [id], target: NotionTarget(type: .page, id: "parent-2", title: "다른 곳"))
    t.expectEqual(Array(rig.api.calls.dropFirst(beforeMove)), ["create:page:title:제목", "append:page-3:1"])
    t.expectEqual(rig.links.link(for: id)?.targetID, "parent-2")

    rig.links.removeAll()
    t.expectNil(rig.links.link(for: id), "로그아웃하면 연결 기록을 지운다")
}

await runner.testAsync("노션 401은 갱신 토큰으로 갱신해 한 번 다시 보내고, 갱신 실패나 갱신 토큰 없음은 다시 로그인 오류") { t in
    let credentials = NotionCredentials(accessToken: "옛토큰", refreshToken: "refresh-1", workspaceName: "내 작업공간", workspaceID: "ws-1", botID: "bot-1")
    let store = MemoryNotionTokenStore()
    try store.save(credentials)
    let relay = ScriptedTransport { _, _ in
        HTTPResult(status: 200, data: Data(#"{"access_token":"새토큰","refresh_token":"refresh-2"}"#.utf8))
    }
    let session = NotionSession(config: notionConfig, store: store, transport: relay)
    let api = ScriptedTransport { _, request in
        request.value(forHTTPHeaderField: "Authorization") == "Bearer 옛토큰"
            ? HTTPResult(status: 401, data: Data())
            : HTTPResult(status: 200, data: Data(#"{"results":[{"object":"page","id":"p1","parent":{"type":"workspace"},"properties":{"이름":{"type":"title","title":[{"plain_text":"할 일"}]}}}]}"#.utf8))
    }
    let items = try await NotionClient(tokens: session, transport: api, sleep: { _ in }).search(query: "")
    t.expectEqual(items, [NotionSearchItem(id: "p1", type: .page, title: "할 일", path: "워크스페이스")])
    t.expectEqual(api.requests.count, 2, "401 뒤 한 번만 다시 보낸다")
    t.expectEqual(relay.requests.count, 1)
    t.expectEqual(relay.requests.first?.url?.absoluteString, "https://relay.example.com/api/notion/token")
    let relayBody = (try? JSONSerialization.jsonObject(with: relay.requests.first?.httpBody ?? Data())) as? [String: Any]
    t.expectEqual(relayBody?["refresh_token"] as? String, "refresh-1")
    t.expectEqual(try store.load()?.accessToken, "새토큰", "갱신한 토큰을 저장")
    t.expectEqual(try store.load()?.refreshToken, "refresh-2")
    t.expectEqual(try store.load()?.workspaceName, "내 작업공간", "갱신 응답에 없는 정보는 유지")

    // 갱신 실패
    let failingStore = MemoryNotionTokenStore()
    try failingStore.save(credentials)
    let failing = NotionSession(config: notionConfig, store: failingStore, transport: ScriptedTransport { _, _ in HTTPResult(status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8)) })
    var reauth = false
    do { _ = try await NotionClient(tokens: failing, transport: ScriptedTransport { _, _ in HTTPResult(status: 401, data: Data()) }, sleep: { _ in }).search(query: "") } catch NotionError.reauthRequired { reauth = true }
    t.expect(reauth, "갱신 실패는 다시 로그인 오류여야 한다")
    t.expect(NotionError.reauthRequired.localizedDescription.contains("다시 로그인해 주세요"))

    // 갱신 토큰이 없음 (중계 호출 없이)
    let noRefreshStore = MemoryNotionTokenStore()
    try noRefreshStore.save(NotionCredentials(accessToken: "옛토큰", workspaceName: "w", workspaceID: "ws-2", botID: "b"))
    let untouchedRelay = ScriptedTransport { _, _ in HTTPResult(status: 200, data: Data()) }
    reauth = false
    do { _ = try await NotionClient(tokens: NotionSession(config: notionConfig, store: noRefreshStore, transport: untouchedRelay), transport: ScriptedTransport { _, _ in HTTPResult(status: 401, data: Data()) }, sleep: { _ in }).search(query: "") } catch NotionError.reauthRequired { reauth = true }
    t.expect(reauth)
    t.expectEqual(untouchedRelay.requests.count, 0)

    // 429는 Retry-After를 지키며 최대 5번 다시 보낸다
    let sleeps = SleepLog()
    let throttled = ScriptedTransport { _, _ in HTTPResult(status: 429, data: Data(), retryAfter: 30) }
    var failed = false
    do { _ = try await NotionClient(tokens: FixedTokens(), transport: throttled, sleep: { sleeps.add($0) }).search(query: "") } catch { failed = true }
    t.expect(failed)
    t.expectEqual(throttled.requests.count, 6)
    t.expect(sleeps.seconds.allSatisfy { $0 >= 30 }, "Retry-After를 지켜야 한다")
}

await runner.testAsync("노션 토큰 저장과 로그아웃 삭제 (메모리 키체인)") { t in
    let store = MemoryNotionTokenStore()
    t.expectNil(try store.load())
    let credentials = NotionCredentials(accessToken: "a", refreshToken: "r", workspaceName: "작업공간", workspaceID: "ws-1", botID: "bot")
    try store.save(credentials)
    t.expectEqual(try store.load(), credentials)
    let session = NotionSession(config: notionConfig, store: store, transport: ScriptedTransport { _, _ in HTTPResult(status: 500, data: Data()) })
    t.expectEqual(await session.current?.workspaceName, "작업공간")
    t.expectEqual(try await session.accessToken(forceRefresh: false), "a")
    try await session.signOut()
    t.expectNil(try store.load(), "키체인 항목이 남았다")
    t.expectNil(await session.current)
    var rejected = false
    do { _ = try await session.accessToken(forceRefresh: false) } catch { rejected = true }
    t.expect(rejected, "로그아웃 뒤에도 토큰을 받았다")

    let defaults = UserDefaults(suiteName: "notion-test-" + UUID().uuidString)!
    let targets = NotionTargetStore(defaults: defaults)
    targets.target = NotionTarget(type: .database, id: "db", title: "표")
    t.expectEqual(targets.target, NotionTarget(type: .database, id: "db", title: "표"))
    targets.target = nil
    t.expectNil(targets.target)
}

runner.test("로그인 결과 페이지는 밖에서 아무것도 불러오지 않고 오류 문구를 이스케이프한다") { t in
    let ok = LoopbackReceiver.resultPage(success: true, message: "", service: "구글 드라이브")
    let bad = LoopbackReceiver.resultPage(success: false, message: "<script>x</script>", service: "노션")
    t.expect(ok.contains("로그인했습니다") && ok.contains("구글 드라이브 연결이 끝났습니다"))
    t.expect(bad.contains("&lt;script&gt;") && !bad.contains("<script>"), "오류 문구가 이스케이프되지 않았다")
    for page in [ok, bad] {
        t.expect(!page.contains("http://") && !page.contains("https://") && !page.contains("@import"), "외부 자원을 부르면 안 된다")
    }
    // 눈으로 확인할 때: MDEMO_DUMP_LOGIN_PAGE=1 make test → 임시 폴더에 두 페이지를 쓴다.
    if ProcessInfo.processInfo.environment["MDEMO_DUMP_LOGIN_PAGE"] == "1" {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        try? ok.write(to: dir.appendingPathComponent("mdemo-login-ok.html"), atomically: true, encoding: .utf8)
        try? bad.write(to: dir.appendingPathComponent("mdemo-login-fail.html"), atomically: true, encoding: .utf8)
    }
}

runner.test("동기화 시각 경계의 현재 동작: 외부 편집 이하와 같은 순간 미만") { t in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sync = SyncService(localRoot: root, remoteRoot: root, stateURL: root.appendingPathComponent("state.json"), keychain: testKeychain)
    // epoch 변환 뒤의 Double 반올림도 현재 동작으로 고정한다.
    let base = Date(timeIntervalSinceReferenceDate: 0)
    let cases: [(Double, Bool, Bool)] = [
        (-0.0006, true, false), (-0.0005, true, true), (-0.0004, true, true),
        (0.0004, true, true), (0.0005, true, true), (0.0006, false, false)
    ]
    for (delta, external, same) in cases {
        let date = base.addingTimeInterval(delta)
        let entry = SyncService.Entry(modified: date, isInTrash: false, hash: "새 지문", fileModified: nil)
        t.expectEqual(sync.isExternalEdit(entry, lastSynced: base, lastHashes: ["옛 지문"]), external)
        t.expectEqual(sync.isSameMoment(base, date), same)
    }
    let boundary = base.timeIntervalSince1970 + 0.0005
    for (value, expected) in [(boundary, true), (boundary.nextUp, false)] {
        let entry = SyncService.Entry(modified: Date(timeIntervalSince1970: value), isInTrash: false, hash: "새 지문", fileModified: nil)
        t.expectEqual(sync.isExternalEdit(entry, lastSynced: base, lastHashes: ["옛 지문"]), expected)
        t.expect(!sync.isExternalEdit(entry, lastSynced: base, lastHashes: nil))
    }
    t.expect(!sync.isSameMoment(nil, base))
}

runner.test("동기화 상태 날짜는 2001 기준 Double이며 정확히 같아야 지문을 채택한다") { t in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("sync-state-google.json")
    let hashesURL = root.appendingPathComponent("sync-state-google.hashes.json")
    let sync = SyncService(localRoot: root, remoteRoot: root, stateURL: url, keychain: testKeychain)
    let date = Date(timeIntervalSinceReferenceDate: 123.25)
    var state = SyncService.SyncState()
    state.record("가짜ID", date: date, hashes: ["a", "b", "a"])
    sync.saveState(state)
    t.expectEqual(try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: url)), ["가짜ID": 123.25])
    let record = try JSONDecoder().decode([String: SyncService.HashRecord].self, from: Data(contentsOf: hashesURL))
    let rawHashes = try JSONSerialization.jsonObject(with: Data(contentsOf: hashesURL)) as! [String: [String: Any]]
    t.expectEqual(rawHashes["가짜ID"]?["date"] as? Double, 123.25)
    t.expectEqual(record["가짜ID"]?.date, date)
    t.expectEqual(sync.loadState().hashes["가짜ID"], ["a", "b"])
    for delta in [-0.0004, 0.0004, 0.0005, 0.0006] {
        try JSONEncoder().encode(["가짜ID": date.addingTimeInterval(delta)]).write(to: url)
        t.expect(sync.loadState().hashes.isEmpty, "거의 같아도 지문을 버려야 한다")
    }
}

runner.finish()
