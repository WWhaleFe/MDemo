import Foundation
import MemoCore
import TestKit

private func shadowMeta(_ id: MemoID) -> MemoMeta {
    MemoMeta(id: id, created: Date(timeIntervalSinceReferenceDate: 800000000.125), modified: Date(timeIntervalSinceReferenceDate: 800000000.125))
}

func registerShadowTests(_ runner: TestRunner) {
    runner.test("그림자는 복제본에서 전 연산을 재생하고 읽기 해시와 개인정보를 검사한다") { t in
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Data")
        var actual = try FileMemoRepository(rootDirectory: root, keychain: TestMemoKeychain())
        actual.clock = { Date(timeIntervalSinceReferenceDate: 800000000.125) }
        let shadow = try ShadowMemoRepository(actual, shadowDirectory: base.appendingPathComponent("Shadow"))
        let id = MemoID.generate(), copy = MemoID.generate()
        let marker = "P7비밀본문표지_노출금지"
        var meta = shadowMeta(id)
        meta.links = [MemoLink(to: copy, kind: .flow)]
        let doc = MemoDocument(meta: meta, body: marker)
        try shadow.save(doc)
        _ = try shadow.load(id: id)
        shadow.waitForShadow()
        _ = try shadow.loadSummaries()
        shadow.waitForShadow()
        try shadow.duplicate(id: id, as: MemoDocument(meta: shadowMeta(copy), body: marker))
        try shadow.moveToTrash(id: copy)
        _ = try shadow.loadTrashSummaries()
        shadow.waitForShadow()
        try shadow.restoreFromTrash(id: copy)
        try shadow.restoreFromTrash(id: copy)
        try shadow.moveToTrash(id: copy)
        try shadow.permanentlyDelete(id: copy)
        t.expect(try actual.load(id: id).meta.links.isEmpty)
        try shadow.moveToTrash(id: id)
        try shadow.emptyTrash(deletedBefore: nil)
        try shadow.saveGroups([marker])
        try shadow.saveBoardLayout(.empty)
        shadow.waitForShadow()
        let text = try String(contentsOf: shadow.shadowDirectory.appendingPathComponent("shadow-log.jsonl"), encoding: .utf8)
        let rows = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        t.expect(!text.contains(marker))
        t.expect(!text.contains(id.rawValue) && !text.contains(copy.rawValue))
        t.expect(!rows.contains { $0["result"] as? String == "error" })
        for name in ["load", "loadSummaries", "loadTrashSummaries"] {
            t.expect(rows.contains { $0["op"] as? String == name && $0["result"] as? String == "same" }, name)
        }
        // 정상 쓰기는 전부 같아야 한다(휴지통 폴더 시각까지).
        let diffs = rows.filter { $0["result"] as? String == "diff" }
        t.expect(diffs.isEmpty, "\(diffs.map { "\($0["op"] ?? "") \($0["paths"] ?? "")" })")
        for name in ["save", "duplicate", "moveToTrash", "permanentlyDelete", "emptyTrash", "saveGroups", "saveBoard"] {
            t.expect(rows.contains { $0["op"] as? String == name && $0["result"] as? String == "same" }, name)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: shadow.shadowDirectory.path)
        t.expectEqual(Set(files), Set(["shadow-log.jsonl", "shadow-summary.json"]))
    }
    runner.test("그림자 손상은 diff이며 Swift 데이터와 오류는 보존한다") { t in
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Data")
        let actual = try FileMemoRepository(rootDirectory: root, keychain: TestMemoKeychain())
        let shadow = try ShadowMemoRepository(actual, shadowDirectory: base.appendingPathComponent("Shadow"))
        let id = MemoID.generate()
        shadow.afterShadowApply = { work in
            try Data("손상표지".utf8).write(to: work.appendingPathComponent("groups.json"))
        }
        try shadow.saveGroups(["정상표지"])
        shadow.waitForShadow()
        t.expectEqual(try actual.loadGroups(), ["정상표지"])
        var failed = false
        do { _ = try shadow.load(id: id) } catch { failed = true }
        shadow.waitForShadow()
        let text = try String(contentsOf: shadow.shadowDirectory.appendingPathComponent("shadow-log.jsonl"), encoding: .utf8)
        t.expect(failed)
        t.expect(text.contains("\"result\":\"diff\""))
        t.expect(text.contains("swift-error"))
        t.expect(!text.contains("정상표지") && !text.contains("손상표지"))
    }
    runner.test("잠긴 메모는 복제 훅에 도달하지 않고 ID 해시만 기록한다") { t in
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Data")
        let actual = try FileMemoRepository(rootDirectory: root, keychain: TestMemoKeychain())
        let shadow = try ShadowMemoRepository(actual, shadowDirectory: base.appendingPathComponent("Shadow"))
        let id = MemoID.generate()
        var meta = shadowMeta(id)
        meta.isLocked = true; meta.lockVersion = 1; meta.lockSalt = "시험솔트"
        let document = MemoDocument(meta: meta, body: Data(repeating: 5, count: 40).base64EncodedString())
        shadow.afterShadowApply = { _ in throw NSError(domain: "복제하면실패", code: 1) }
        try shadow.save(document)
        _ = try shadow.load(id: id)
        try shadow.moveToTrash(id: id)
        shadow.waitForShadow()
        let text = try String(contentsOf: shadow.shadowDirectory.appendingPathComponent("shadow-log.jsonl"), encoding: .utf8)
        let rows = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        t.expectEqual(rows.count, 3)
        t.expect(rows.allSatisfy { $0["skipped"] as? String == "locked" && $0["id"] as? String != nil })
        t.expect(!text.contains(id.rawValue) && !text.contains(document.body))
        t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: shadow.shadowDirectory.path).count, 2)
    }
    runner.test("그림자는 읽기 경쟁을 재검사하고 요약은 한 시간 동안 한 번만 비교한다") { t in
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let actual = try FileMemoRepository(rootDirectory: base.appendingPathComponent("Data"), keychain: TestMemoKeychain())
        let shadow = try ShadowMemoRepository(actual, shadowDirectory: base.appendingPathComponent("Shadow"))
        let id = MemoID.generate()
        let first = MemoDocument(meta: shadowMeta(id), body: "처음본문")
        try actual.save(first)
        let blocked = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        shadow.afterShadowApply = { _ in blocked.signal(); resume.wait() }
        try shadow.saveGroups([])
        blocked.wait()
        shadow.afterShadowApply = nil
        _ = try shadow.load(id: id)
        try actual.save(MemoDocument(meta: first.meta, body: "뒤본문"))
        resume.signal()
        shadow.waitForShadow()
        _ = try shadow.loadSummaries(); _ = try shadow.loadSummaries()
        shadow.waitForShadow()
        let text = try String(contentsOf: shadow.shadowDirectory.appendingPathComponent("shadow-log.jsonl"), encoding: .utf8)
        let rows = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        t.expect(rows.contains { $0["op"] as? String == "load" && $0["result"] as? String == "same" })
        t.expectEqual(rows.filter { $0["op"] as? String == "loadSummaries" }.count, 1)
    }
    runner.test("500MB 복제 용량과 200건 대기 상한은 Swift 저장을 막지 않는다") { t in
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let actual = try FileMemoRepository(rootDirectory: base.appendingPathComponent("Data"), keychain: TestMemoKeychain())
        let shadow = try ShadowMemoRepository(actual, shadowDirectory: base.appendingPathComponent("Shadow"))
        let doc = MemoDocument(meta: shadowMeta(.generate()), body: "용량시험")
        try actual.save(doc)
        let attachments = actual.attachmentsDirectory(for: doc.meta.id)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let sparse = attachments.appendingPathComponent("large.bin")
        _ = FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 501 * 1024 * 1024); try handle.close()
        try shadow.save(doc)
        try FileManager.default.removeItem(at: sparse)
        let blocked = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        shadow.afterShadowApply = { _ in blocked.signal(); resume.wait() }
        try shadow.saveGroups([])
        blocked.wait()
        shadow.afterShadowApply = nil
        for _ in 0..<201 { try shadow.saveGroups(["대기시험"]) }
        resume.signal(); shadow.waitForShadow()
        let text = try String(contentsOf: shadow.shadowDirectory.appendingPathComponent("shadow-log.jsonl"), encoding: .utf8)
        let rows = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        t.expect(rows.filter { $0["skipped"] as? String == "backlog" }.count >= 3)
        t.expectEqual(try actual.loadGroups(), ["대기시험"])
        t.expectEqual(try actual.load(id: doc.meta.id).body, doc.body)
    }
    runner.test("그림자 mtime 비교는 휴지통 폴더만, 1마이크로초 이하만 허용한다") { t in
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let actual = try FileMemoRepository(rootDirectory: base.appendingPathComponent("Data"), keychain: TestMemoKeychain())
        let shadow = try ShadowMemoRepository(actual, shadowDirectory: base.appendingPathComponent("Shadow"))
        let id = MemoID.generate()
        // 파일 시스템이 찍는 memo.md 시각은 비교하지 않는다(독립된 두 저장은 시각이 다를 수밖에 없다).
        shadow.afterShadowApply = { before in
            let file = before.appendingPathComponent("memos/\(id.rawValue)/memo.md")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path)
        }
        try shadow.save(MemoDocument(meta: shadowMeta(id), body: "시각시험"))
        shadow.waitForShadow()
        let trash = "trash/\(id.rawValue)"
        for delta in [0.0000005, 0.000002] {
            shadow.afterShadowApply = { before in
                let after = before.deletingLastPathComponent().appendingPathComponent("after").appendingPathComponent(trash)
                let attrs = try FileManager.default.attributesOfItem(atPath: after.path)
                let date = (attrs[.modificationDate] as! Date).addingTimeInterval(delta)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: before.appendingPathComponent(trash).path)
            }
            try shadow.moveToTrash(id: id)
            shadow.waitForShadow()
            shadow.afterShadowApply = nil
            try actual.restoreFromTrash(id: id)
        }
        let text = try String(contentsOf: shadow.shadowDirectory.appendingPathComponent("shadow-log.jsonl"), encoding: .utf8)
        let rows = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        t.expectEqual(rows.map { $0["result"] as? String }, ["same", "same", "diff"])
    }
    runner.test("그림자 꺼짐은 FileMemoRepository 값을 그대로 돌려준다") { t in
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var actual = try FileMemoRepository(rootDirectory: root, keychain: TestMemoKeychain())
        actual.beforeMemoWrite = { _, _ in throw NSError(domain: "원본훅", code: 7) }
        let wrapped = CoreShadow.wrap(actual, dataRoot: root)
        t.expect(wrapped is FileMemoRepository)
        t.expectEqual((wrapped as? FileMemoRepository)?.rootDirectory, root)
        do { try wrapped.save(MemoDocument(meta: shadowMeta(.generate()), body: "")); t.expect(false) }
        catch { t.expectEqual((error as NSError).code, 7) }
    }
    runner.test("그림자 저장 한 건의 추가 동기 시간 측정") { t in
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let actual = try FileMemoRepository(rootDirectory: base.appendingPathComponent("Data"), keychain: TestMemoKeychain())
        let shadow = try ShadowMemoRepository(actual, shadowDirectory: base.appendingPathComponent("Shadow"))
        let doc = MemoDocument(meta: shadowMeta(.generate()), body: String(repeating: "시험본문\n", count: 200))
        try actual.save(doc)
        var plain: [Double] = [], decorated: [Double] = []
        for _ in 0..<30 {
            var start = Date(); try actual.save(doc); plain.append(Date().timeIntervalSince(start) * 1000)
            start = Date(); try shadow.save(doc); decorated.append(Date().timeIntervalSince(start) * 1000)
            shadow.waitForShadow()
        }
        let extra = zip(decorated, plain).map(-).sorted()
        print("    P7 저장 추가 시간 ms: 중앙값 \(extra[15]), p95 \(extra[28]), 최대 \(extra[29])")
        t.expectEqual(try actual.load(id: doc.meta.id).body, doc.body)
    }
}
