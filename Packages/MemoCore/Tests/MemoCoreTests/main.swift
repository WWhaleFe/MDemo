import Foundation
import MemoCore
import TestKit

let runner = TestRunner("MemoCore")

// MARK: - 식별자와 모델

runner.test("ULID는 26자이며 생성 시각순으로 정렬된다") { t in
    let earlier = MemoID.generate(date: Date(timeIntervalSince1970: 1_000_000))
    let later = MemoID.generate(date: Date(timeIntervalSince1970: 2_000_000))

    t.expect(earlier.isValid, "이른 ID가 유효하지 않음: \(earlier)")
    t.expect(later.isValid, "늦은 ID가 유효하지 않음: \(later)")
    t.expectEqual(earlier.rawValue.count, 26)
    t.expect(earlier.rawValue < later.rawValue, "ULID는 문자열 정렬이 곧 시간순 정렬이어야 한다")
}

runner.test("같은 시각에 만들어도 ID는 충돌하지 않는다") { t in
    let now = Date()
    let ids = Set((0..<500).map { _ in MemoID.generate(date: now).rawValue })
    t.expectEqual(ids.count, 500, "중복 ID 발생")
}

runner.test("알파값은 하한선 아래로 내려가지 않는다 (OPA-03)") { t in
    let floored = MemoMeta(id: .generate(), backgroundAlpha: 0.0, textAlpha: 0.0)
    t.expectEqual(floored.backgroundAlpha, 0.15, "배경 알파 하한")
    t.expectEqual(floored.textAlpha, 0.3, "텍스트 알파 하한")

    let capped = MemoMeta(id: .generate(), backgroundAlpha: 2.0, textAlpha: 2.0)
    t.expectEqual(capped.backgroundAlpha, 1.0, "배경 알파 상한")
    t.expectEqual(capped.textAlpha, 1.0, "텍스트 알파 상한")
}

runner.test("배경색 프리셋 8가지가 모두 유효한 16진수다 (WIN-11)") { t in
    t.expectEqual(MemoColor.presets.count, 8)
    for preset in MemoColor.presets {
        t.expectNotNil(MemoColor.components(fromHex: preset.hex), "\(preset.name) 색상 파싱 실패")
    }
    t.expectNil(MemoColor.components(fromHex: "#XYZ"), "잘못된 색상 문자열은 거부해야 한다")
}

// MARK: - 프론트매터 (DOC-02)

runner.test("프론트매터는 왕복해도 값이 보존된다") { t in
    let meta = MemoMeta(
        id: .generate(),
        group: "업무",
        colorHex: "#FFF3B0",
        backgroundAlpha: 0.85,
        textAlpha: 0.7,
        isOpen: true,
        isPinned: false
    )
    let original = MemoDocument(meta: meta, body: "# 제목\n본문 내용\n- [ ] 할 일")

    let encoded = FrontmatterCodec.encode(original)
    let decoded = try FrontmatterCodec.decode(fileContents: encoded)

    t.expectEqual(decoded.meta.id, meta.id)
    t.expectEqual(decoded.meta.group, "업무")
    t.expectEqual(decoded.meta.colorHex, "#FFF3B0")
    t.expectEqual(decoded.meta.backgroundAlpha, 0.85)
    t.expectEqual(decoded.meta.textAlpha, 0.7)
    t.expectEqual(decoded.meta.isOpen, true)
    t.expectEqual(decoded.meta.isPinned, false)
    t.expectEqual(decoded.body, original.body, "본문이 변형되면 안 된다")
}

runner.test("본문의 --- 구분선은 프론트매터로 오인되지 않는다 (MD-12)") { t in
    let meta = MemoMeta(id: .generate())
    let body = "위 문단\n\n---\n\n아래 문단"
    let encoded = FrontmatterCodec.encode(MemoDocument(meta: meta, body: body))
    let decoded = try FrontmatterCodec.decode(fileContents: encoded)
    t.expectEqual(decoded.body, body)
}

runner.test("모르는 프론트매터 필드는 보존된다 (상위 버전 호환)") { t in
    let id = MemoID.generate()
    let text = """
    ---
    schemaVersion: 1
    id: \(id.rawValue)
    color: "#FFF3B0"
    futureField: 미래에추가될값
    ---
    본문
    """
    let decoded = try FrontmatterCodec.decode(fileContents: text)
    t.expect(decoded.unknownFrontmatterLines.contains { $0.contains("futureField") }, "모르는 필드가 버려졌다")

    let reencoded = FrontmatterCodec.encode(decoded)
    t.expect(reencoded.contains("futureField"), "저장 시 모르는 필드가 사라지면 안 된다")
}

runner.test("수정 시각은 밀리초까지 보존된다 (SYNC-06 충돌 판정 기준)") { t in
    let precise = Date(timeIntervalSince1970: 1_700_000_000.456)
    let meta = MemoMeta(id: .generate(), created: precise, modified: precise)
    let decoded = try FrontmatterCodec.decode(fileContents: FrontmatterCodec.encode(MemoDocument(meta: meta, body: "")))

    let drift = abs(decoded.meta.modified.timeIntervalSince1970 - precise.timeIntervalSince1970)
    t.expect(drift < 0.01, "시각 오차가 \(drift)초 — 같은 초에 일어난 두 기기의 수정을 구분할 수 없다")
}

runner.test("소수점 없이 기록된 시각도 읽을 수 있다 (손으로 편집한 파일)") { t in
    let id = MemoID.generate()
    let text = """
    ---
    id: \(id.rawValue)
    modified: 2026-08-26T03:49:54Z
    ---
    본문
    """
    let decoded = try FrontmatterCodec.decode(fileContents: text)
    t.expect(decoded.meta.modified.timeIntervalSince1970 > 1_700_000_000, "예전 형식 시각 파싱 실패")
}

runner.test("한글 그룹명과 따옴표가 든 값도 안전하게 왕복한다") { t in
    let meta = MemoMeta(id: .generate(), group: "업무: \"중요\" 항목")
    let encoded = FrontmatterCodec.encode(MemoDocument(meta: meta, body: ""))
    let decoded = try FrontmatterCodec.decode(fileContents: encoded)
    t.expectEqual(decoded.meta.group, "업무: \"중요\" 항목")
}

runner.test("구분자가 없는 파일은 오류로 거부한다") { t in
    do {
        _ = try FrontmatterCodec.decode(fileContents: "구분자 없는 그냥 텍스트")
        t.expect(false, "오류가 발생해야 한다")
    } catch let error as FrontmatterError {
        t.expectEqual(error, .missingOpeningDelimiter)
    }
}

// MARK: - 파일 저장소 (DAT-08, IMG-07, TRS-01)

func makeTemporaryRepository() throws -> (FileMemoRepository, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MemoAppTests-\(UUID().uuidString)", isDirectory: true)
    return (try FileMemoRepository(rootDirectory: root), root)
}

runner.test("저장한 메모를 그대로 다시 읽는다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let meta = MemoMeta(id: .generate(), group: "개인")
    let document = MemoDocument(meta: meta, body: "장보기 목록\n- [ ] 우유")
    try repository.save(document)

    let loaded = try repository.load(id: meta.id)
    t.expectEqual(loaded.body, document.body)
    t.expectEqual(loaded.meta.group, "개인")

    // 메모 하나가 폴더 하나 (설계서 §3-1)
    let expectedPath = root.appendingPathComponent("memos/\(meta.id.rawValue)/memo.md").path
    t.expect(FileManager.default.fileExists(atPath: expectedPath), "예상 경로에 파일이 없음: \(expectedPath)")
}

runner.test("요약 목록은 본문 전체를 읽지 않고도 제목과 미리보기를 만든다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let longBody = "# 회의록\n" + String(repeating: "긴 본문 내용입니다. ", count: 3000)
    let meta = MemoMeta(id: .generate())
    try repository.save(MemoDocument(meta: meta, body: longBody))

    let summaries = try repository.loadSummaries()
    t.expectEqual(summaries.count, 1)
    t.expectEqual(summaries.first?.title, "회의록")
    t.expect((summaries.first?.preview.count ?? 0) <= 200, "미리보기가 200자를 넘으면 안 된다")
}

runner.test("요약은 수정일 최신순으로 정렬된다 (SRC-03)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let older = MemoMeta(id: .generate(), modified: Date(timeIntervalSince1970: 1_000_000))
    let newer = MemoMeta(id: .generate(), modified: Date(timeIntervalSince1970: 2_000_000))
    try repository.save(MemoDocument(meta: older, body: "예전 메모"))
    try repository.save(MemoDocument(meta: newer, body: "최근 메모"))

    let summaries = try repository.loadSummaries()
    t.expectEqual(summaries.first?.id, newer.id, "최신 메모가 앞에 와야 한다")
}

runner.test("덮어 써도 이전 내용이 남지 않는다 (원자적 저장, DAT-08)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let meta = MemoMeta(id: .generate())
    try repository.save(MemoDocument(meta: meta, body: "아주 긴 원래 내용을 여기에 넣는다"))
    try repository.save(MemoDocument(meta: meta, body: "짧게"))

    let loaded = try repository.load(id: meta.id)
    t.expectEqual(loaded.body, "짧게", "이전 내용의 잔재가 남았다")
}

runner.test("휴지통 이동 시 첨부 폴더까지 함께 간다 (TRS-01, TRS-05)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let meta = MemoMeta(id: .generate())
    try repository.save(MemoDocument(meta: meta, body: "사진 있는 메모"))

    let attachments = repository.attachmentsDirectory(for: meta.id)
    try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
    try Data("가짜 이미지".utf8).write(to: attachments.appendingPathComponent("img.png"))

    try repository.moveToTrash(id: meta.id)

    t.expectEqual(try repository.loadSummaries().count, 0, "휴지통 메모가 목록에 남아 있다")
    let trashedImage = root.appendingPathComponent("trash/\(meta.id.rawValue)/attachments/img.png")
    t.expect(FileManager.default.fileExists(atPath: trashedImage.path), "첨부가 함께 이동하지 않았다")
}

runner.test("깨진 파일 하나가 다른 메모 목록을 막지 않는다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let healthy = MemoMeta(id: .generate())
    try repository.save(MemoDocument(meta: healthy, body: "정상 메모"))

    let brokenID = MemoID.generate()
    let brokenDirectory = root.appendingPathComponent("memos/\(brokenID.rawValue)", isDirectory: true)
    try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
    try Data("깨진 내용".utf8).write(to: brokenDirectory.appendingPathComponent("memo.md"))

    let summaries = try repository.loadSummaries()
    t.expectEqual(summaries.count, 1, "정상 메모는 읽혀야 한다")
    t.expectEqual(summaries.first?.id, healthy.id)
}

// MARK: - 기기별 상태 (SYNC-07)

// MARK: - MemoStore (단일 진실 공급원, §4-3)

runner.test("본문을 저장하면 파일과 요약이 함께 갱신된다 (DAT-03)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    try MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        let meta = store.createMemo()

        store.saveBody(id: meta.id, body: "# 장보기\n- [ ] 우유")

        // 파일에 실제로 기록됐는가
        let reloaded = try repository.load(id: meta.id)
        t.expectEqual(reloaded.body, "# 장보기\n- [ ] 우유")

        // 목록 요약도 즉시 반영됐는가 (리스트 창과 스티키 창이 서로를 보게 하는 경로)
        t.expectEqual(store.summaries.first(where: { $0.id == meta.id })?.title, "장보기")
        // 저장 정밀도가 1ms이므로 그만큼의 절삭은 허용한다.
        let drift = reloaded.meta.modified.timeIntervalSince1970 - meta.modified.timeIntervalSince1970
        t.expect(drift >= -0.001, "수정 시각이 뒤로 돌아갔다 (\(drift)초)")
    }
}

runner.test("열림 상태는 파일에 남아 재시작 복원의 근거가 된다 (WIN-06, SYNC-08)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    try MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        let opened = store.createMemo()
        let closed = store.createMemo()

        store.setOpen(id: closed.id, isOpen: false)

        t.expectEqual(store.openMemos.count, 1, "열린 메모만 남아야 한다")
        t.expectEqual(store.openMemos.first?.id, opened.id)

        // 새 인스턴스가 파일에서 다시 읽어도 같아야 한다 (재시작 시나리오)
        let restarted = MemoStore(repository: repository)
        t.expectEqual(restarted.openMemos.count, 1)
        t.expectEqual(restarted.openMemos.first?.id, opened.id)
    }
}

runner.test("휴지통으로 옮기면 목록에서 사라진다 (TRS-01)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        let meta = store.createMemo()
        t.expectEqual(store.summaries.count, 1)

        store.moveToTrash(id: meta.id)
        t.expectEqual(store.summaries.count, 0)
    }
}

// MARK: - 기기별 상태 (SYNC-07)

runner.test("기기별 창 상태는 따로 저장되고 다시 읽힌다") { t in
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("device-state-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let id = MemoID.generate()
    let store = DeviceStateStore(fileURL: url)
    store.setState(DeviceMemoState(frame: [100, 200, 300, 400], displayID: "MAIN"), for: id)
    store.flush()

    let reopened = DeviceStateStore(fileURL: url)
    t.expectEqual(reopened.state(for: id)?.frame, [100, 200, 300, 400])
    t.expectEqual(reopened.state(for: id)?.displayID, "MAIN")
}

runner.finish()
