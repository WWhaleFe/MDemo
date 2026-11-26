import CoreBridge
import CryptoKit
import Foundation

/// 실제 저장소의 결과와 오류를 그대로 돌려주고 별도 복제본만 Rust에 쓴다.
public final class ShadowMemoRepository: MemoRepository, @unchecked Sendable {
    private let actual: FileMemoRepository
    public let shadowDirectory: URL
    private let queue = DispatchQueue(label: "MDemo.shadow", qos: .utility)
    private let gate = NSRecursiveLock()
    private let state = NSLock()
    private var pending = 0
    private var reserved: UInt64 = 0
    private var lastRead: [String: Date] = [:]
    private var counts: [String: [String: Int]] = [:]
    private let started: Date
    /// 시험 전용: Rust 연산 뒤 복제본 손상을 주입한다. 실제 폴더는 전달하지 않는다.
    private var hook: (@Sendable (URL) throws -> Void)?
    public var afterShadowApply: (@Sendable (URL) throws -> Void)? {
        get { state.lock(); defer { state.unlock() }; return hook }
        set { state.lock(); defer { state.unlock() }; hook = newValue }
    }
    private let fm = FileManager.default
    private static let limit: UInt64 = 500 * 1024 * 1024

    public init(_ actual: FileMemoRepository, shadowDirectory: URL) throws {
        self.actual = actual
        self.shadowDirectory = shadowDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let root = actual.rootDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard self.shadowDirectory.path != root,
              !self.shadowDirectory.path.hasPrefix(root + "/") else { throw ShadowFailure.invalidRoot }
        for folder in ["memos", "trash"] {
            let attrs = try fm.attributesOfItem(atPath: actual.rootDirectory.appendingPathComponent(folder).path)
            guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else { throw ShadowFailure.link }
        }
        try fm.createDirectory(at: self.shadowDirectory, withIntermediateDirectories: true)
        reserved = try Self.bytes(at: self.shadowDirectory)
        if let data = try? Data(contentsOf: self.shadowDirectory.appendingPathComponent("shadow-summary.json")),
           let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let operations = summary["operations"] as? [String: [String: Int]],
           let timestamp = summary["started"] as? Double, timestamp.isFinite {
            counts = operations
            started = Date(timeIntervalSinceReferenceDate: timestamp)
        } else { started = Date() }
    }

    private enum ShadowFailure: Error { case invalidRoot, link; case locked(MemoID) }
    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func short(_ id: String) -> String { String(hash(id).prefix(12)) }
    private static func bytes(at url: URL) throws -> UInt64 {
        let m = try FileManager.default.attributesOfItem(atPath: url.path)
        if m[.type] as? FileAttributeType == .typeSymbolicLink { throw ShadowFailure.link }
        if m[.type] as? FileAttributeType != .typeDirectory { return (m[.size] as? NSNumber)?.uint64Value ?? 0 }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .reduce(0) { try $0 + bytes(at: $1) }
    }
    /// 첨부 이름에도 제목 등이 들어갈 수 있으므로 알려진 고정 이름 이외에는 해시만 남긴다.
    private static func safePath(_ path: String) -> String {
        let directory = path.hasPrefix("dir:")
        let raw = directory ? String(path.dropFirst(4)) : path
        let fixed: Set<String> = ["memos", "trash", "memo.md", "attachments", "groups.json", "board.json", "destroyed.json", "local-only.json"]
        return (directory ? "dir:" : "") + raw.split(separator: "/").map {
            fixed.contains(String($0)) ? String($0) : short(String($0))
        }.joined(separator: "/")
    }
    private func log(_ op: String, id: MemoID?, result: String, reason: String? = nil, details: [[String: Any]] = []) {
        let now = Date()
        var row: [String: Any] = ["ts": now.timeIntervalSinceReferenceDate, "op": op, "result": result]
        if let id { row["id"] = Self.short(id.rawValue) }
        if let reason { row["skipped"] = reason }
        if !details.isEmpty { row["paths"] = details.map { $0["path"]! }; row["entries"] = details }
        counts[op, default: [:]][result, default: 0] += 1
        // 오류의 localizedDescription은 본문이나 사용자 경로를 포함할 수 있어 기록하지 않는다.
        do {
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            let file = shadowDirectory.appendingPathComponent("shadow-log.jsonl")
            if !fm.fileExists(atPath: file.path) { _ = fm.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10]))
            let summary: [String: Any] = ["started": started.timeIntervalSinceReferenceDate, "last": now.timeIntervalSinceReferenceDate, "operations": counts]
            try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
                .write(to: shadowDirectory.appendingPathComponent("shadow-summary.json"), options: .atomic)
        } catch { }
    }
    private func record(_ op: String, id: MemoID?, result: String, reason: String? = nil) {
        queue.async { self.log(op, id: id, result: result, reason: reason) }
    }
    /// 비동기 비교가 끝날 때까지 기다리는 시험용 경계.
    public func waitForShadow() { queue.sync {} }
    private func reserve(_ bytes: UInt64) -> Bool {
        state.lock(); defer { state.unlock() }
        guard pending < 200, reserved <= Self.limit, bytes <= Self.limit - reserved else { return false }
        pending += 1; reserved += bytes
        return true
    }
    private func release(_ bytes: UInt64) {
        state.lock(); defer { state.unlock() }
        pending -= 1; reserved -= bytes
    }
    private func finish(_ round: URL, budget: UInt64) {
        do { try fm.removeItem(at: round); release(budget) }
        catch {
            // 지우지 못한 복제본의 예약량은 남겨 다음 회차의 상한에 포함한다.
            state.lock(); pending -= 1; state.unlock()
        }
    }
    private func lockedMemoIDs(_ paths: [String], incoming: MemoDocument?) -> (ids: [MemoID], unreadable: Bool) {
        var ids = Set<MemoID>()
        var unreadable = false
        if let incoming, incoming.meta.isLocked { ids.insert(incoming.meta.id) }
        for path in paths {
            let url = actual.rootDirectory.appendingPathComponent(path)
            var candidates: [URL] = []
            if ["memos", "trash"].contains(path) {
                candidates = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                    .map { $0.appendingPathComponent("memo.md") }
            } else if path.hasPrefix("memos/") || path.hasPrefix("trash/") {
                candidates = [url.appendingPathComponent("memo.md")]
            }
            for file in candidates {
                // 잠금 판단을 위해 키체인을 열거나 복호화하지 않는다.
                guard fm.fileExists(atPath: file.path) else { continue }
                let parent = try? fm.attributesOfItem(atPath: file.deletingLastPathComponent().path)
                guard parent?[.type] as? FileAttributeType != .typeSymbolicLink,
                      let document = header(file) else { unreadable = true; continue }
                if document.meta.isLocked { ids.insert(document.meta.id) }
            }
        }
        return (Array(ids), unreadable)
    }
    private func header(_ file: URL) -> MemoDocument? {
        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var bytes = Data()
        while let part = try? handle.read(upToCount: 4096), !part.isEmpty {
            bytes.append(part)
            if let text = String(data: bytes, encoding: .utf8),
               let doc = try? FrontmatterCodec.decode(fileContents: text) { return doc }
        }
        return nil
    }
    private func snapshot(_ paths: [String], to root: URL) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for path in paths {
            let source = actual.rootDirectory.appendingPathComponent(path)
            guard fm.fileExists(atPath: source.path) else { continue }
            // 호출자가 용량과 링크를 검사한 경로만 복제한다.
            let destination = root.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
        }
        for folder in ["memos", "trash"] {
            let target = root.appendingPathComponent(folder)
            if !fm.fileExists(atPath: target.path) { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
        }
        // 복제 자체가 바꾼 부모 폴더 시각을 원본 시각으로 복원한다.
        for path in ["memos", "trash", ""] {
            let attrs = try fm.attributesOfItem(atPath: actual.rootDirectory.appendingPathComponent(path).path)
            if let date = attrs[.modificationDate] { try fm.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent(path).path) }
        }
    }
    private func write(_ name: String, id: MemoID? = nil, paths: [String], incoming: MemoDocument? = nil,
                       operation: @escaping @Sendable (URL) throws -> ShadowBridge.Operation,
                       swift: () throws -> Void) throws {
        gate.lock(); defer { gate.unlock() }
        let inspection = lockedMemoIDs(paths, incoming: incoming)
        let lockedIDs = inspection.ids
        let locked = !lockedIDs.isEmpty
        var round: URL?
        var budget: UInt64 = 0
        var beforeSize: UInt64 = 0
        var skip = inspection.unreadable ? "unreadable" : "backlog"
        if !locked && !inspection.unreadable {
            do {
                let size = try paths.reduce(UInt64(0)) { total, path in
                    let url = actual.rootDirectory.appendingPathComponent(path)
                    return try total + (fm.fileExists(atPath: url.path) ? Self.bytes(at: url) : 0)
                }
                beforeSize = size
                // 두 복제본과 원자적 쓰기 임시 파일, 새 본문의 여유 공간을 예약한다.
                budget = size * 3 + UInt64(incoming.map { $0.body.utf8.count * 2 } ?? 0) + 1024 * 1024
                if reserve(budget) {
                    let url = shadowDirectory.appendingPathComponent(UUID().uuidString)
                    round = url
                    try snapshot(paths, to: url.appendingPathComponent("before"))
                }
            } catch { skip = "snapshot-error"; if round != nil { finish(round!, budget: budget); round = nil } }
        }
        do { try swift() } catch {
            if let round { finish(round, budget: budget) }
            record(name, id: id, result: "skipped", reason: "swift-error")
            throw error
        }
        guard let round else {
            if locked { for lockedID in lockedIDs { record(name, id: lockedID, result: "skipped", reason: "locked") } }
            else if skip == "snapshot-error" { record(name, id: id, result: "error") }
            else { record(name, id: id, result: "skipped", reason: skip) }
            return
        }
        do {
            let afterSize = try paths.reduce(UInt64(0)) { total, path in
                let url = actual.rootDirectory.appendingPathComponent(path)
                return try total + (fm.fileExists(atPath: url.path) ? Self.bytes(at: url) : 0)
            }
            let needed = beforeSize + afterSize
            if needed > budget {
                state.lock()
                let extra = needed - budget
                let fits = reserved <= Self.limit && extra <= Self.limit - reserved
                if fits { reserved += extra; budget = needed }
                state.unlock()
                if !fits {
                    finish(round, budget: budget)
                    record(name, id: id, result: "skipped", reason: "backlog")
                    return
                }
            }
            try snapshot(paths, to: round.appendingPathComponent("after"))
            let hook = afterShadowApply
            let booked = budget
            queue.async {
                defer { self.finish(round, budget: booked) }
                do {
                    let before = round.appendingPathComponent("before")
                    let op = try operation(round.appendingPathComponent("after"))
                    try ShadowBridge.apply(before, operation: op)
                    try hook?(before)
                    let rust = try ShadowBridge.tree(before)
                    let swift = try ShadowBridge.tree(round.appendingPathComponent("after"))
                    let r = Dictionary(uniqueKeysWithValues: rust.map { ($0.path, $0) })
                    let s = Dictionary(uniqueKeysWithValues: swift.map { ($0.path, $0) })
                    var details: [[String: Any]] = []
                    for path in Set(r.keys).union(s.keys).sorted() {
                        let a = s[path], b = r[path]
                        // 저장소가 시각을 직접 정하는 곳은 휴지통 폴더(삭제 시각)뿐이다. 나머지 파일 · 폴더 mtime은
                        // 파일 시스템이 쓰는 순간을 찍으므로 두 구현이 같을 수 없어 바이트 · 크기만 비교한다.
                        let timed = path.hasPrefix("dir:trash/") && path.dropFirst("dir:trash/".count).split(separator: "/").count == 1
                        if let a, let b, a.sha256 == b.sha256, a.size == b.size,
                           !timed || abs(a.mtime - b.mtime) <= 0.000001 { continue }
                        func fields(_ e: ShadowBridge.Entry?) -> Any {
                            guard let e else { return NSNull() }
                            return ["sha256": e.sha256, "size": e.size, "mtime": e.mtime] as [String: Any]
                        }
                        details.append(["path": Self.safePath(path), "swift": fields(a), "rust": fields(b)])
                    }
                    self.log(name, id: id, result: details.isEmpty ? "same" : "diff", details: details)
                } catch { self.log(name, id: id, result: "error") }
            }
        } catch {
            finish(round, budget: budget)
            record(name, id: id, result: "error")
        }
    }
    private func paths(_ ids: [MemoID]) -> [String] {
        ids.flatMap { ["memos/\($0.rawValue)", "trash/\($0.rawValue)"] } + ["destroyed.json", "local-only.json"]
    }
    private func deletionPaths(_ ids: [MemoID]) -> [String] {
        let targets = Set(ids)
        var result = Set(paths(ids))
        for folder in ["memos", "trash"] {
            let root = actual.rootDirectory.appendingPathComponent(folder)
            for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                guard let doc = header(entry.appendingPathComponent("memo.md")),
                      doc.meta.links.contains(where: { targets.contains($0.to) }) else { continue }
                result.insert("\(folder)/\(entry.lastPathComponent)")
            }
        }
        return result.sorted()
    }
    private func trashIDs(before date: Date?) -> [MemoID] {
        let root = actual.rootDirectory.appendingPathComponent("trash")
        return ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).compactMap {
            let id = MemoID(rawValue: $0.lastPathComponent)
            guard id.isValid else { return nil }
            if let date, let at = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, at >= date { return nil }
            return id
        }
    }
    private func memoText(_ id: MemoID, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent("memos/\(id.rawValue)/memo.md"), encoding: .utf8)
    }
    private func deletionTime(_ id: MemoID, root: URL) throws -> Double {
        let attrs = try fm.attributesOfItem(atPath: root.appendingPathComponent("trash/\(id.rawValue)").path)
        return (attrs[.modificationDate] as! Date).timeIntervalSinceReferenceDate
    }
    public func save(_ document: MemoDocument) throws {
        try write("save", id: document.meta.id, paths: paths([document.meta.id]), incoming: document,
                  operation: { root in .save(memoText: try self.memoText(document.meta.id, root: root)) }) { try actual.save(document) }
    }
    public func duplicate(id: MemoID, as document: MemoDocument) throws {
        try write("duplicate", id: document.meta.id, paths: paths([id, document.meta.id]), incoming: document,
                  operation: { root in .duplicate(sourceId: id.rawValue, memoText: try self.memoText(document.meta.id, root: root)) }) { try actual.duplicate(id: id, as: document) }
    }
    public func moveToTrash(id: MemoID) throws {
        try write("moveToTrash", id: id, paths: paths([id]), operation: { root in
            .moveToTrash(id: id.rawValue, at: (try? self.deletionTime(id, root: root)) ?? 0)
        }) { try actual.moveToTrash(id: id) }
    }
    public func restoreFromTrash(id: MemoID) throws {
        try write("restore", id: id, paths: paths([id]), operation: { _ in .restore(id: id.rawValue) }) { try actual.restoreFromTrash(id: id) }
    }
    public func permanentlyDelete(id: MemoID) throws {
        try write("permanentlyDelete", id: id, paths: deletionPaths([id]), operation: { root in
            .permanentlyDelete(id: id.rawValue, at: try self.linkChangeTime(root: root))
        }) { try actual.permanentlyDelete(id: id) }
    }
    private func linkChangeTime(root: URL) throws -> Double {
        // 실제 연결 정리 결과의 modified를 시계에 전달한다.
        let repo = try FileMemoRepository(rootDirectory: root, keychain: ShadowEmptyKeychain())
        let docs = try repo.loadSummaries() + repo.loadTrashSummaries()
        let before = root.deletingLastPathComponent().appendingPathComponent("before")
        return docs.compactMap { doc -> Double? in
            let folder = doc.deletedAt == nil ? "memos" : "trash"
            let old = header(before.appendingPathComponent("\(folder)/\(doc.id.rawValue)/memo.md"))
            guard let old, old.meta.links != doc.meta.links else { return nil }
            return doc.meta.modified.timeIntervalSinceReferenceDate
        }.max() ?? 0
    }
    public func emptyTrash(deletedBefore date: Date?) throws {
        try write("emptyTrash", paths: deletionPaths(trashIDs(before: date)), operation: { root in
            .emptyTrash(before: date?.timeIntervalSinceReferenceDate, at: try self.linkChangeTime(root: root))
        }) { try actual.emptyTrash(deletedBefore: date) }
    }
    public func saveGroups(_ groups: [String]) throws {
        try write("saveGroups", paths: ["groups.json"], operation: { root in
            .saveGroups(json: try String(contentsOf: root.appendingPathComponent("groups.json"), encoding: .utf8))
        }) { try actual.saveGroups(groups) }
    }
    public func saveBoardLayout(_ layout: BoardLayout) throws {
        try write("saveBoard", paths: ["board.json"], operation: { root in
            .saveBoard(json: try String(contentsOf: root.appendingPathComponent("board.json"), encoding: .utf8))
        }) { try actual.saveBoardLayout(layout) }
    }
    private static func summaryHashes(_ values: [MemoSummary]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.map {
            let meta = FrontmatterCodec.encode(MemoDocument(meta: $0.meta, body: ""))
            return ($0.id.rawValue, hash(meta + "\0" + $0.preview + "\0" + ($0.deletedAt.map { String(describing: $0.timeIntervalSinceReferenceDate) } ?? "")))
        })
    }
    private func read(_ name: String, id: MemoID?, locked: Bool, expected: @escaping @Sendable () -> [String: String],
                      fresh: @escaping @Sendable () throws -> [String: String],
                      rust: @escaping @Sendable () throws -> [String: String], throttle: Bool = false) {
        if locked { record(name, id: id, result: "skipped", reason: "locked"); return }
        state.lock()
        if throttle, let last = lastRead[name], Date().timeIntervalSince(last) < 3600 { state.unlock(); return }
        if throttle { lastRead[name] = Date() }
        state.unlock()
        guard reserve(0) else { record(name, id: id, result: "skipped", reason: "backlog"); return }
        queue.async {
            defer { self.release(0) }
            do {
                var s = expected()
                var r: [String: String]
                do { r = try rust() }
                catch {
                    do { s = try fresh() }
                    catch ShadowFailure.locked(let lockedID) {
                        self.log(name, id: lockedID, result: "skipped", reason: "locked")
                        return
                    } catch {
                        self.log(name, id: id, result: "skipped", reason: "changed")
                        return
                    }
                    r = try rust()
                }
                if s != r {
                    do { s = try fresh() }
                    catch ShadowFailure.locked(let lockedID) {
                        self.log(name, id: lockedID, result: "skipped", reason: "locked")
                        return
                    } catch {
                        self.log(name, id: id, result: "skipped", reason: "changed")
                        return
                    }
                    r = try rust()
                    guard s == (try fresh()) else {
                        self.log(name, id: id, result: "skipped", reason: "changed")
                        return
                    }
                }
                let keys = Set(s.keys).union(r.keys).filter { s[$0] != r[$0] }.sorted()
                let details: [[String: Any]] = keys.map { key in
                    func fields(_ digest: String?) -> Any {
                        guard let digest else { return NSNull() }
                        return ["sha256": digest, "size": NSNull(), "mtime": NSNull()] as [String: Any]
                    }
                    let folder = name == "loadTrashSummaries" ? "trash" : "memos"
                    let suffix = name == "load" ? "memo.md" : "summary"
                    return ["path": "\(folder)/\(Self.short(key))/\(suffix)", "swift": fields(s[key]), "rust": fields(r[key])]
                }
                self.log(name, id: id, result: keys.isEmpty ? "same" : "diff", details: details)
            } catch ShadowFailure.locked(let lockedID) {
                self.log(name, id: lockedID, result: "skipped", reason: "locked")
            } catch { self.log(name, id: id, result: "error") }
        }
    }
    public func load(id: MemoID) throws -> MemoDocument {
        let doc: MemoDocument
        do { doc = try actual.load(id: id) } catch { record("load", id: id, result: "skipped", reason: "swift-error"); throw error }
        read("load", id: id, locked: doc.meta.isLocked,
             expected: { [id.rawValue: Self.hash(FrontmatterCodec.encode(doc))] },
             fresh: {
                 let doc = try self.actual.load(id: id)
                 guard !doc.meta.isLocked else { throw ShadowFailure.locked(id) }
                 return [id.rawValue: Self.hash(FrontmatterCodec.encode(doc))]
             },
             rust: { [id.rawValue: try ShadowBridge.load(self.actual.rootDirectory, id: id.rawValue)] })
        return doc
    }
    private func summaries(trash: Bool) throws -> [MemoSummary] {
        let name = trash ? "loadTrashSummaries" : "loadSummaries"
        let values: [MemoSummary]
        do { values = try trash ? actual.loadTrashSummaries() : actual.loadSummaries() }
        catch { record(name, id: nil, result: "skipped", reason: "swift-error"); throw error }
        let locked = values.filter { $0.meta.isLocked }
        if !locked.isEmpty {
            for value in locked { record(name, id: value.id, result: "skipped", reason: "locked") }
            return values
        }
        read(name, id: nil, locked: false, expected: { Self.summaryHashes(values) },
             fresh: {
                 let values = try trash ? self.actual.loadTrashSummaries() : self.actual.loadSummaries()
                 if let locked = values.first(where: { $0.meta.isLocked }) { throw ShadowFailure.locked(locked.id) }
                 return Self.summaryHashes(values)
             },
             rust: { try ShadowBridge.summaries(self.actual.rootDirectory, trash: trash) }, throttle: true)
        return values
    }
    public func loadSummaries() throws -> [MemoSummary] { try summaries(trash: false) }
    public func loadTrashSummaries() throws -> [MemoSummary] { try summaries(trash: true) }
    public func loadGroups() throws -> [String] { try actual.loadGroups() }
    public func loadBoardLayout() throws -> BoardLayout { try actual.loadBoardLayout() }
    public func attachmentsDirectory(for id: MemoID) -> URL { actual.attachmentsDirectory(for: id) }
    public func pruneUnusedAttachments(modifiedBefore date: Date) -> Int { actual.pruneUnusedAttachments(modifiedBefore: date) }
    public func searchBodies(matching query: String, in ids: [MemoID]) throws -> Set<MemoID> { try actual.searchBodies(matching: query, in: ids) }
}

private struct ShadowEmptyKeychain: MemoKeychain {
    func read(id: MemoID) throws -> Data? { nil }
    func write(_ value: Data, id: MemoID) throws {}
    func delete(id: MemoID) throws {}
    func readFailures(id: MemoID) throws -> Int { 0 }
    func writeFailures(_ count: Int, id: MemoID) throws {}
}

public enum CoreShadow {
    public static func wrap(_ repo: FileMemoRepository, dataRoot: URL) -> any MemoRepository {
        guard (Bundle.main.object(forInfoDictionaryKey: "MDemoRustShadow") as? Bool) == true || CommandLine.arguments.contains("--rust-shadow") else { return repo }
        let overridden = CommandLine.arguments.contains { $0.hasPrefix("--data-dir=") }
        let folder = dataRoot.deletingLastPathComponent().appendingPathComponent(overridden ? dataRoot.lastPathComponent + "-shadow" : "Shadow")
        return (try? ShadowMemoRepository(repo, shadowDirectory: folder)) ?? repo
    }
}
