import Foundation
import CryptoKit
import MemoCore

// 암호 메모 시나리오 실행기 (P4). 실제 MemoStore · FileMemoRepository와 파일로 이어지는 가짜 키체인을 쓴다.
// 데이터 폴더의 keychain.json이 키체인 상태다. Rust 실행기와 같은 형식이라 서로의 결과를 이어 받는다.
// 이 키체인은 시험용이며 실제 키체인(Security)에는 닿지 않는다.

/// 열쇠와 실패 횟수 글자를 메모리에 두고 `keychain.json`에 내보내는 대역. DeviceMemoKeychain과 같은 계약이다.
final class FileBackedKeychain: MemoKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var keys: [String: Data] = [:]
    private var failures: [String: Data] = [:]

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: String]] else {
            throw ScenarioError("keychain.json 형식 오류")
        }
        for (id, text) in root["keys"] ?? [:] { keys[id] = Data(base64Encoded: text) }
        for (id, text) in root["failures"] ?? [:] { failures[id] = Data(text.utf8) }
    }

    /// 변경이 있을 때마다 내보낸다(중간에 실패해도 상태가 남는다).
    func save() throws {
        let object: [String: Any] = [
            "keys": keys.mapValues { $0.base64EncodedString() },
            "failures": failures.mapValues { String(decoding: $0, as: UTF8.self) },
        ]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
    }

    func read(id: MemoID) throws -> Data? { lock.lock(); defer { lock.unlock() }; return keys[id.rawValue] }
    func write(_ wrappedKey: Data, id: MemoID) throws {
        lock.lock(); defer { lock.unlock() }
        keys[id.rawValue] = wrappedKey
        try save()
    }
    func delete(id: MemoID) throws {
        lock.lock(); defer { lock.unlock() }
        keys[id.rawValue] = nil
        failures[id.rawValue] = nil
        try save()
    }
    func readFailures(id: MemoID) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let data = failures[id.rawValue] else { return 0 }
        guard let text = String(data: data, encoding: .utf8), let count = Int(text), count >= 0 else { throw MemoLockError.damaged }
        return count
    }
    func writeFailures(_ count: Int, id: MemoID) throws {
        lock.lock(); defer { lock.unlock() }
        failures[id.rawValue] = Data(String(count).utf8)
        try save()
    }
    func writeRawFailures(_ text: String, id: MemoID) throws {
        lock.lock(); defer { lock.unlock() }
        failures[id.rawValue] = Data(text.utf8)
        try save()
    }
}

/// 두 실행기가 같은 이름을 쓰도록 오류 종류를 글자로 바꾼다.
private func errorKind(_ error: Error) -> String {
    if let lockError = error as? MemoLockError {
        switch lockError {
        case .invalidPassword: return "invalidPassword"
        case .missingKey: return "missingKey"
        case .wrongPassword: return "wrongPassword"
        case .damaged: return "damaged"
        case .locked: return "locked"
        case .destroyed: return "destroyed"
        case .keychain: return "keyStore"
        }
    }
    if let crypto = error as? CryptoKitError {
        switch crypto {
        case .authenticationFailure: return "authentication"
        case .incorrectParameterSize: return "incorrectSize"
        default: return "other"
        }
    }
    return "other"
}

@MainActor
func runLockScenario(file: URL, dataDir: URL, phase: Int?) async throws {
    guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
          let ops = root["ops"] as? [[String: Any]]
    else { throw ScenarioError("시나리오 형식 오류") }
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    let keychain = try FileBackedKeychain(url: dataDir.appendingPathComponent("keychain.json"))
    let context = try ScenarioContext(dataDir: dataDir, keychain: keychain)
    let store = context.store
    store.calibrateIterations = { 2_000_000 }
    let fm = FileManager.default
    defer { try? keychain.save() }

    for (index, op) in ops.enumerated() {
        if let phase, (op["phase"] as? Int ?? 1) != phase { continue }
        func string(_ key: String) throws -> String {
            guard let value = op[key] as? String else { throw ScenarioError("\(index + 1)번 연산에 \(key)가 없음") }
            return value
        }
        func id(_ key: String = "id") throws -> MemoID { MemoID(rawValue: try string(key)) }
        let name = try string("op")
        if op["time"] is String { context.clock.now = try parseTime(try string("time")) }
        let expected = op["expect"] as? String ?? "ok"
        /// 결과(오류 종류)를 기록하고 기대와 맞는지 확인한다.
        func finish(_ work: () async throws -> Void) async throws {
            var kind = "ok"
            do { try await work() } catch { kind = errorKind(error) }
            print("\(index + 1) \(name) \(kind)")
            guard kind == expected else { throw ScenarioError("\(index + 1)번 \(name): 결과 \(kind), 기대 \(expected)") }
        }

        switch name {
        case "createLocked":
            context.clock.nextID = try id()
            try await finish {
                let source = (op["source"] as? String).map { MemoID(rawValue: $0) }
                let created = try await store.createLockedMemo(password: try string("password"), moving: source)
                guard created == (try id()) else { throw ScenarioError("만들어진 ID가 다름") }
            }
        case "unlock":
            try await finish { try await store.unlock(id: try id(), password: try string("password")) }
        case "relock":
            store.relock(try id())
            print("\(index + 1) relock ok")
        case "changePassword":
            try await finish { try await store.changePassword(id: try id(), password: try string("password")) }
        case "moveToPlain":
            context.clock.nextID = try id("newId")
            try await finish {
                let created = try store.moveToPlainMemo(id: try id())
                guard created == (try id("newId")) else { throw ScenarioError("만들어진 ID가 다름") }
            }
        case "destroy":
            try await finish { try store.destroyMemo(id: try id()) }
        case "saveLockedBody":
            let saved = store.saveBody(id: try id(), body: try string("body"))
            let kind = saved ? "ok" : "refused"
            print("\(index + 1) saveLockedBody \(kind)")
            guard kind == expected else { throw ScenarioError("\(index + 1)번 saveLockedBody: 결과 \(kind), 기대 \(expected)") }
        case "loadTrash":
            store.reloadTrash()
            print("\(index + 1) loadTrash ok")
        case "setFailures":
            let target = try id()
            if let value = op["keychain"] as? Int { try keychain.writeFailures(value, id: target) }
            if let raw = op["rawKeychain"] as? String { try keychain.writeRawFailures(raw, id: target) }
            if let value = op["header"] as? Int {
                var document = try context.repo.load(id: target)
                document.meta.lockFailures = value
                try context.repo.save(document)
            }
            print("\(index + 1) setFailures ok")
        case "corruptBody":
            var document = try context.repo.load(id: try id())
            guard var cipher = Data(base64Encoded: document.body), cipher.count > 14 else { throw ScenarioError("손상시킬 암호문이 없음") }
            cipher[14] ^= 1
            document.body = cipher.base64EncodedString()
            try context.repo.save(document)
            print("\(index + 1) corruptBody ok")
        case "flipByte":
            let url = dataDir.appendingPathComponent(try string("path"))
            var data = try Data(contentsOf: url)
            let offset = op["offset"] as? Int ?? 0
            data[data.startIndex + (offset >= 0 ? offset : data.count + offset)] ^= 1
            try data.write(to: url, options: .atomic)
            print("\(index + 1) flipByte ok")
        case "writeFile":
            try Data(try string("text").utf8).write(to: dataDir.appendingPathComponent(try string("path")))
            print("\(index + 1) writeFile ok")
        case "assertBody":
            try await finish {
                let document = try store.decryptedDocument(id: try id())
                guard document.body == (try string("body")) else { throw ScenarioError("본문이 다름") }
            }
        case "assertAttachment":
            try await finish {
                guard let session = store.lockSession(for: try id()) else { throw MemoLockError.locked }
                let file = store.attachmentsDirectory(for: try id()).appendingPathComponent(try string("name") + ".enc")
                let plain = try session.open(Data(contentsOf: file), name: try string("name"))
                guard plain == Data(base64Encoded: try string("bytes")) else { throw ScenarioError("첨부가 다름") }
            }
        case "assertFailures":
            let target = try id()
            let inKeychain = try keychain.readFailures(id: target)
            let inHeader = try context.repo.load(id: target).meta.lockFailures
            print("\(index + 1) assertFailures keychain=\(inKeychain) header=\(inHeader.map(String.init) ?? "nil")")
            if let want = op["keychain"] as? Int, want != inKeychain { throw ScenarioError("\(index + 1)번: 키체인 횟수 \(inKeychain), 기대 \(want)") }
            if let want = op["header"] as? Int, want != inHeader { throw ScenarioError("\(index + 1)번: 앞머리 횟수 \(inHeader.map(String.init) ?? "nil"), 기대 \(want)") }
        case "assertExists":
            let exists = fm.fileExists(atPath: dataDir.appendingPathComponent(try string("path")).path)
            print("\(index + 1) assertExists \(exists)")
            if exists != (op["exists"] as? Bool ?? true) { throw ScenarioError("\(index + 1)번: \(try string("path")) 존재 \(exists)") }
        default:
            guard try context.apply(op, index: index) else { throw ScenarioError("알 수 없는 연산: \(name)") }
            print("\(index + 1) \(name) ok")
        }
    }
}
