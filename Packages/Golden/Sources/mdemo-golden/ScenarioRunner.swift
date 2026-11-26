import Foundation
import MemoCore

// 데이터 폴더 시나리오 실행기 (P3). 실제 FileMemoRepository와 MemoStore로 연산을 수행한다.
// 시각과 ID는 시나리오의 고정값을 주입한다. 키체인은 빈 대역이고 데이터 폴더는 호출자가 준다.

/// 저장소와 MemoStore가 함께 읽는 현재 시각 · 다음 ID.
final class ScenarioClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 0)
    var nextID = MemoID(rawValue: "")
}

struct ScenarioError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func parseTime(_ text: String) throws -> Date {
    for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        if let date = formatter.date(from: text) { return date }
    }
    throw ScenarioError("시각을 읽을 수 없음: \(text)")
}

/// 저장소 · MemoStore · 주입 시계를 묶은 실행 환경. `lock` 시나리오도 같은 연산을 재사용한다.
@MainActor
final class ScenarioContext {
    let clock = ScenarioClock()
    var repo: FileMemoRepository
    let store: MemoStore
    let dataDir: URL

    init(dataDir: URL, keychain: any MemoKeychain) throws {
        self.dataDir = dataDir
        let clock = self.clock
        var repo = try FileMemoRepository(rootDirectory: dataDir, keychain: keychain)
        repo.clock = { clock.now }
        self.repo = repo
        store = MemoStore(repository: repo, keychain: keychain)
        store.clock = { clock.now }
        store.generateID = { clock.nextID }
    }

    /// 공통 연산 하나를 수행한다. 모르는 연산이면 false.
    func apply(_ op: [String: Any], index: Int) throws -> Bool {
        let fm = FileManager.default
        func string(_ key: String) throws -> String {
            guard let value = op[key] as? String else { throw ScenarioError("\(index + 1)번 연산에 \(key)가 없음") }
            return value
        }
        func id(_ key: String = "id") throws -> MemoID { MemoID(rawValue: try string(key)) }
        func time(_ key: String) throws -> Date { try parseTime(string(key)) }
        let name = try string("op")
        if op["time"] is String { clock.now = try time("time") }
        switch name {
        case "create":
            clock.nextID = try id()
            store.createMemo(colorHex: op["colorHex"] as? String ?? MemoColor.presets[0].hex, group: op["group"] as? String)
        case "saveBody":
            store.saveBody(id: try id(), body: try string("body"))
        case "updateMeta":
            store.updateMeta(id: try id()) { meta in
                if let value = op["colorHex"] as? String { meta.colorHex = value }
                if op["group"] != nil { meta.group = op["group"] as? String }
                if op["title"] != nil { meta.title = op["title"] as? String }
                if let value = op["isOpen"] as? Bool { meta.isOpen = value }
                if let value = op["isPinned"] as? Bool { meta.isPinned = value }
            }
        case "link":
            guard let kind = MemoLinkKind(rawValue: try string("kind")) else { throw ScenarioError("알 수 없는 연결 종류") }
            store.link(from: try id("from"), to: try id("to"), kind: kind)
        case "moveToTrash":
            store.moveToTrash(ids: [try id()])
        case "restore":
            store.restoreFromTrash(ids: [try id()])
        case "deletePermanently":
            store.permanentlyDelete(ids: [try id()])
        case "emptyTrash":
            clock.now = try time("now")
            store.emptyTrash(olderThan: op["days"] as? Int ?? 30, now: clock.now)
        case "emptyTrashAll":
            store.emptyTrash()
        case "addAttachment":
            // Swift에는 이름을 정해 저장하는 길이 없다(`AttachmentImages.save`는 이미지를 풀고 무작위 이름을 쓴다).
            // 폴더 아래에 같은 이름과 바이트로 원자적으로 쓰는 것으로 맞춘다.
            guard let data = Data(base64Encoded: try string("bytes")) else { throw ScenarioError("base64 오류") }
            let directory = store.attachmentsDirectory(for: try id())
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(try string("name")), options: .atomic)
        case "removeAttachment":
            // 이름으로 지우는 길도 Swift에는 없다(미사용 정리만 있다). 파일을 직접 지운다.
            let url = store.attachmentsDirectory(for: try id()).appendingPathComponent(try string("name"))
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        case "pruneUnusedAttachments":
            clock.now = try time("now")
            repo.pruneUnusedAttachments(modifiedBefore: clock.now.addingTimeInterval(-Double(op["days"] as? Int ?? 1) * 86_400))
        case "setBoardPlacements":
            var placements: [MemoID: BoardLayout.Placement] = [:]
            for (key, value) in op["placements"] as? [String: [String: Double]] ?? [:] {
                placements[MemoID(rawValue: key)] = .init(x: value["x"] ?? 0, y: value["y"] ?? 0)
            }
            store.setBoardPlacements(placements)
        case "setGroups":
            try repo.saveGroups(op["groups"] as? [String] ?? [])
        case "ledgerInsert":
            try MemoPrivacyLedger.insert(try id(), name: try string("name"), root: dataDir)
        case "touch":
            try fm.setAttributes([.modificationDate: try time("time")], ofItemAtPath: dataDir.appendingPathComponent(try string("path")).path)
        default:
            return false
        }
        return true
    }
}

@MainActor
func runScenario(file: URL, dataDir: URL) throws {
    guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
          let ops = root["ops"] as? [[String: Any]]
    else { throw ScenarioError("시나리오 형식 오류") }
    let context = try ScenarioContext(dataDir: dataDir, keychain: EmptyKeychain())
    for (index, op) in ops.enumerated() {
        guard try context.apply(op, index: index) else {
            throw ScenarioError("알 수 없는 연산: \(op["op"] as? String ?? "")")
        }
    }
}
