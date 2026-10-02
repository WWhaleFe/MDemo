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

runner.test("제목은 프론트매터에 남고 왕복해도 그대로다 (TXT-06)") { t in
    let meta = MemoMeta(id: .generate(), title: "장보기 목록")
    let encoded = FrontmatterCodec.encode(MemoDocument(meta: meta, body: "우유"))
    t.expect(encoded.contains("title: \"장보기 목록\""), "제목 줄이 없다:\n\(encoded)")

    let decoded = try FrontmatterCodec.decode(fileContents: encoded)
    t.expectEqual(decoded.meta.title, "장보기 목록")
    t.expectEqual(decoded.meta.schemaVersion, MemoMeta.currentSchemaVersion)
}

runner.test("제목이 없던 옛 파일도 그대로 읽힌다 (v1 → v2 마이그레이션)") { t in
    let id = MemoID.generate()
    let old = """
    ---
    schemaVersion: 1
    id: \(id.rawValue)
    color: "#FFF3B0"
    bgAlpha: 0.9
    textAlpha: 1.0
    open: true
    pinned: true
    created: 2026-08-26T00:00:00.000Z
    modified: 2026-08-26T00:00:00.000Z
    ---
    첫 줄이 제목 노릇을 한다
    """

    let decoded = try FrontmatterCodec.decode(fileContents: old)
    t.expectEqual(decoded.meta.title, nil, "없던 제목이 생겼다")
    t.expectEqual(decoded.meta.schemaVersion, MemoMeta.currentSchemaVersion, "스키마 버전이 올라가지 않았다")

    // 제목이 없으면 목록에는 본문 첫 줄이 보인다 (TXT-05).
    let summary = MemoSummary(meta: decoded.meta, preview: decoded.body)
    t.expectEqual(summary.title, "첫 줄이 제목 노릇을 한다")
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
        .appendingPathComponent("MDemoTests-\(UUID().uuidString)", isDirectory: true)
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

// MARK: - 그룹 (LST-02, LST-03)

runner.test("그룹을 만들고 이름을 바꾸면 메모의 이름표도 따라간다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        store.createGroup(named: "업무")
        let meta = store.createMemo(group: "업무")

        t.expect(store.groups.contains("업무"))
        t.expectEqual(store.memoCount(inGroup: "업무"), 1)

        store.renameGroup(from: "업무", to: "회사")
        t.expect(store.groups.contains("회사"), "그룹 이름이 바뀌지 않았다")
        t.expectEqual(store.summaries.first(where: { $0.id == meta.id })?.meta.group, "회사", "메모의 그룹이 따라오지 않았다")
    }
}

runner.test("그룹을 지워도 메모는 남는다 (그룹 없음으로)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        store.createGroup(named: "임시")
        let meta = store.createMemo(group: "임시")

        store.deleteGroup("임시")
        t.expect(!store.groups.contains("임시"), "그룹이 지워지지 않았다")
        t.expectEqual(store.summaries.count, 1, "그룹을 지웠다고 메모가 사라지면 안 된다")
        t.expectNil(store.summaries.first(where: { $0.id == meta.id })?.meta.group)
    }
}

runner.test("그룹 목록은 다시 열어도 유지된다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        store.createGroup(named: "업무")
        store.createGroup(named: "개인")

        let reopened = MemoStore(repository: repository)
        t.expect(reopened.groups.contains("업무") && reopened.groups.contains("개인"), "그룹이 저장되지 않았다")
    }
}

// MARK: - 휴지통 (TRS-01~04)

runner.test("휴지통으로 옮긴 메모를 되돌릴 수 있다 (TRS-02)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        let meta = store.createMemo()
        store.saveBody(id: meta.id, body: "지우면 안 되는 내용")

        store.moveToTrash(id: meta.id)
        t.expectEqual(store.summaries.count, 0, "목록에서 사라져야 한다")
        t.expectEqual(store.trashed.count, 1, "휴지통에 있어야 한다")

        store.restoreFromTrash(id: meta.id)
        t.expectEqual(store.summaries.count, 1, "복원되지 않았다")
        t.expectEqual(store.trashed.count, 0, "휴지통에 남아 있다")
        t.expectEqual(store.loadDocument(id: meta.id)?.body, "지우면 안 되는 내용", "내용이 보존되지 않았다")
    }
}

runner.test("영구 삭제하면 파일까지 사라진다 (TRS-04)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        let meta = store.createMemo()
        store.moveToTrash(id: meta.id)
        store.permanentlyDelete(id: meta.id)

        t.expectEqual(store.trashed.count, 0)
        let path = root.appendingPathComponent("trash/\(meta.id.rawValue)").path
        t.expect(!FileManager.default.fileExists(atPath: path), "파일이 남아 있다")
    }
}

runner.test("보관 기간이 지나지 않은 항목은 자동으로 지워지지 않는다 (TRS-03)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        let meta = store.createMemo()
        store.moveToTrash(id: meta.id)

        store.emptyTrash(olderThan: 30)
        t.expectEqual(store.trashed.count, 1, "방금 버린 메모가 사라졌다")

        store.emptyTrash()
        t.expectEqual(store.trashed.count, 0, "즉시 비우기가 동작하지 않았다")
    }
}

runner.test("오래 고치지 않은 메모도 버린 날부터 보관 기간을 센다 (TRS-03)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        let meta = store.createMemo()
        // 40일 전에 마지막으로 고친 메모처럼 만든다.
        let old = Date().addingTimeInterval(-40 * 24 * 60 * 60)
        let folder = root.appendingPathComponent("memos/\(meta.id.rawValue)")
        if !FileManager.default.fileExists(atPath: folder.path) {
            // 저장 위치 이름이 바뀌어도 시험이 조용히 빗나가지 않게 실제 폴더를 찾는다.
            let found = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?
                .first { $0.hasSuffix(meta.id.rawValue) }
            t.expectNotNil(found, "메모 폴더를 찾지 못했다")
            if let found {
                try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(found).path)
            }
        } else {
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        }

        store.moveToTrash(id: meta.id)
        store.emptyTrash(olderThan: 30)
        t.expectEqual(store.trashed.count, 1, "방금 버린 오래된 메모가 바로 지워졌다")
    }
}

runner.test("버린 지 보관 기간이 지난 항목은 자동으로 지워진다 (TRS-03)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        let kept = store.createMemo()
        let expired = store.createMemo()
        store.moveToTrash(ids: [kept.id, expired.id])

        let old = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        let trashed = root.appendingPathComponent("trash/\(expired.id.rawValue)").path
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: trashed)

        store.emptyTrash(olderThan: 30)
        t.expectEqual(store.trashed.map(\.id), [kept.id], "기한이 지난 것만 지워져야 한다")
    }
}

// MARK: - 검색과 정렬 (SRC-01~03)

runner.test("제목과 본문 모두에서 찾는다 (SRC-01)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        let titleHit = store.createMemo()
        store.saveBody(id: titleHit.id, body: "# 장보기 목록\n우유")

        let bodyHit = store.createMemo()
        // 제목에는 없고 본문 뒤쪽에만 있는 낱말 — 미리보기 범위를 넘어간다
        store.saveBody(id: bodyHit.id, body: "# 회의록\n" + String(repeating: "내용 ", count: 200) + "장보기")

        let miss = store.createMemo()
        store.saveBody(id: miss.id, body: "# 다른 메모\n관계없는 내용")

        let results = store.search(query: "장보기")
        t.expectEqual(results.count, 2, "제목과 본문 양쪽에서 찾아야 한다")
        t.expect(results.contains { $0.id == titleHit.id }, "제목으로 찾지 못했다")
        t.expect(results.contains { $0.id == bodyHit.id }, "본문으로 찾지 못했다")
        t.expect(!results.contains { $0.id == miss.id }, "관계없는 메모가 걸렸다")
    }
}

runner.test("그룹으로 검색 범위를 좁힌다 (SRC-02)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        let work = store.createMemo(group: "업무")
        store.saveBody(id: work.id, body: "회의 준비")
        let personal = store.createMemo(group: "개인")
        store.saveBody(id: personal.id, body: "회의 참석")

        t.expectEqual(store.search(query: "회의").count, 2)
        t.expectEqual(store.search(query: "회의", group: "업무").count, 1)
        t.expectEqual(store.search(query: "회의", group: "업무").first?.id, work.id)
    }
}

runner.test("빈 검색어는 전체를 돌려준다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        store.createMemo()
        store.createMemo()
        t.expectEqual(store.search(query: "").count, 2)
        t.expectEqual(store.search(query: "   ").count, 2)
    }
}

runner.test("정렬 기준과 방향이 모두 동작한다 (SRC-03)") { t in
    let older = MemoSummary(
        meta: MemoMeta(id: .generate(), created: Date(timeIntervalSince1970: 100), modified: Date(timeIntervalSince1970: 100)),
        preview: "나중 제목"
    )
    let newer = MemoSummary(
        meta: MemoMeta(id: .generate(), created: Date(timeIntervalSince1970: 200), modified: Date(timeIntervalSince1970: 200)),
        preview: "가나다 제목"
    )
    let list = [older, newer]

    t.expectEqual(MemoSearch.sorted(list, by: .newestFirst).first?.id, newer.id, "최신순 정렬 실패")
    t.expectEqual(MemoSearch.sorted(list, by: MemoSortOrder(key: .modified, ascending: true)).first?.id, older.id)
    t.expectEqual(MemoSearch.sorted(list, by: MemoSortOrder(key: .title, ascending: true)).first?.id, newer.id, "제목 오름차순 실패")
    t.expectEqual(MemoSearch.sorted(list, by: MemoSortOrder(key: .created, ascending: false)).first?.id, newer.id)
}

runner.test("메모 1,000개에서도 검색이 0.3초 안에 끝난다 (NFR-05)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    // 실제 사용에 가까운 분량으로 만든다 — 메모당 30줄.
    let body = "# 회의록\n" + (0..<30).map { "- [ ] 항목 \($0) 내용입니다" }.joined(separator: "\n")
    var needleID: MemoID?
    for index in 0..<1000 {
        let meta = MemoMeta(id: .generate())
        // 제목·미리보기에는 없고 본문 끝에만 있는 낱말 — 가장 비싼 경로를 재게 한다.
        let text = index == 777 ? body + "\n숨겨진낱말특별표시" : body
        try repository.save(MemoDocument(meta: meta, body: text))
        if index == 777 { needleID = meta.id }
    }

    try MainActor.assumeIsolated {
        let store = MemoStore(repository: repository)
        t.expectEqual(store.summaries.count, 1000, "1,000개가 모두 읽히지 않았다")

        let started = Date()
        let results = store.search(query: "숨겨진낱말특별표시")
        let elapsed = Date().timeIntervalSince(started)

        t.expectEqual(results.count, 1, "본문에만 있는 낱말을 찾지 못했다")
        t.expectEqual(results.first?.id, needleID)
        t.expect(elapsed < 0.3, String(format: "검색에 %.3f초 걸렸다 (목표 0.3초)", elapsed))

        // 제목으로 찾는 경우는 파일을 읽지 않으므로 훨씬 빨라야 한다.
        let quickStart = Date()
        _ = store.search(query: "회의록")
        let quickElapsed = Date().timeIntervalSince(quickStart)
        t.expect(quickElapsed < 0.1, String(format: "제목 검색에 %.3f초 걸렸다", quickElapsed))
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
