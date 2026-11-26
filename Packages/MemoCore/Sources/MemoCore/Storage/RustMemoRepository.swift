import CoreBridge
import Foundation

/// 파일 해석과 쓰기는 Rust에 맡기고 검색 판정과 목록 순서는 플랫폼 기준을 따른다.
public final class RustMemoRepository: MemoRepository, @unchecked Sendable {
    public let rootDirectory: URL
    private let core: CoreRepository
    public init(rootDirectory: URL, keychain: any MemoKeychain = DeviceMemoKeychain()) throws {
        self.rootDirectory = rootDirectory
        do { core = try CoreRepository(root: rootDirectory.path, keys: RepositoryKeyStore(keychain)) }
        catch let error as CoreRepositoryError { throw Self.convert(error) }
    }
    func makeLockStore() throws -> RustLockBridge { try call { RustLockBridge(core: try core.lockStore()) } }
    public func setClockForTesting(_ date: Date) { core.setClockForTesting(at: date.timeIntervalSinceReferenceDate) }
    private func call<T>(_ action: () throws -> T) throws -> T {
        do { return try action() }
        catch let error as CoreRepositoryError { throw Self.convert(error) }
    }
    static func convert(_ error: CoreRepositoryError) -> Error {
        switch error {
        case .Destroyed: return MemoLockError.destroyed
        case .Damaged: return MemoLockError.damaged
        case .Locked: return MemoLockError.locked
        case .MissingKey: return MemoLockError.missingKey
        case .WrongPassword: return MemoLockError.wrongPassword
        case .InvalidPassword: return MemoLockError.invalidPassword
        case .Keychain(let status): return MemoLockError.keychain(status)
        case .NotFound: return CocoaError(.fileReadNoSuchFile)
        case .Format: return MemoLockError.damaged
        case .Io(let message): return NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    private func ordered(_ values: [CoreMemoSummary], trash: Bool) -> [MemoSummary] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: rootDirectory.appendingPathComponent(trash ? "trash" : "memos"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let ranks = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.lastPathComponent, $0.offset) })
        let summaries = values.map { MemoSummary(meta: $0.meta.native, preview: $0.preview, deletedAt: $0.deletedAt.map { Date(timeIntervalSinceReferenceDate: $0) }) }
        return summaries.sorted { (ranks[$0.id.rawValue] ?? 0) < (ranks[$1.id.rawValue] ?? 0) }.sorted {
            trash ? ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) : $0.meta.modified > $1.meta.modified
        }
    }
    public func loadSummaries() throws -> [MemoSummary] { try call { ordered(try core.loadSummaries(), trash: false) } }
    public func loadTrashSummaries() throws -> [MemoSummary] { try call { ordered(try core.loadTrashSummaries(), trash: true) } }
    public func load(id: MemoID) throws -> MemoDocument { try call { try core.load(id: id.rawValue).native } }
    public func save(_ document: MemoDocument) throws { try call { try core.save(document: document.record) } }
    public func duplicate(id: MemoID, as document: MemoDocument) throws { try call { try core.duplicate(id: id.rawValue, document: document.record) } }
    public func moveToTrash(id: MemoID) throws { try call { try core.moveToTrash(id: id.rawValue) } }
    public func restoreFromTrash(id: MemoID) throws { try call { try core.restoreFromTrash(id: id.rawValue) } }
    public func permanentlyDelete(id: MemoID) throws { try call { try core.permanentlyDelete(id: id.rawValue) } }
    public func emptyTrash(deletedBefore date: Date?) throws { try call { try core.emptyTrash(before: date?.timeIntervalSinceReferenceDate) } }
    public func attachmentsDirectory(for id: MemoID) -> URL { URL(fileURLWithPath: core.attachmentsDirectory(id: id.rawValue), isDirectory: true) }
    public func pruneUnusedAttachments(modifiedBefore date: Date) -> Int { Int(core.pruneUnusedAttachments(before: date.timeIntervalSinceReferenceDate)) }
    public func loadGroups() throws -> [String] { core.loadGroups() }
    public func saveGroups(_ groups: [String]) throws { try call { try core.saveGroups(groups: groups) } }
    public func loadBoardLayout() throws -> BoardLayout {
        let b = core.loadBoardLayout()
        return BoardLayout(placements: Dictionary(uniqueKeysWithValues: b.placements.map { ($0.id, .init(x: $0.x, y: $0.y)) }), bentoSpans: Dictionary(uniqueKeysWithValues: b.bentoSpans.compactMap { s in BoardLayout.BentoSpan(rawValue: s.span).map { (s.id, $0) } }), manualOrder: b.manualOrder.map { MemoID(rawValue: $0) })
    }
    public func saveBoardLayout(_ layout: BoardLayout) throws {
        try call { try core.saveBoardLayout(layout: CoreBoardLayout(placements: layout.placements.map { CorePlacement(id: $0.key, x: $0.value.x, y: $0.value.y) }, bentoSpans: layout.bentoSpans.map { CoreBentoSpan(id: $0.key, span: $0.value.rawValue) }, manualOrder: layout.manualOrder.map(\.rawValue))) }
    }
    public func destroyed() throws -> Set<String> { try call { Set(try core.destroyed()) } }
    public func localOnly() throws -> Set<String> { try call { Set(try core.localOnly()) } }
    public func searchBodies(matching query: String, in ids: [MemoID]) throws -> Set<MemoID> {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var found: Set<MemoID> = []
        for id in ids {
            guard let document = try? core.loadForSearch(id: id.rawValue), !document.meta.isLocked else { continue }
            if document.body.localizedCaseInsensitiveContains(needle) { found.insert(id) }
        }
        return found
    }
}

/// 키체인 접근은 Swift에 남긴다. delete는 기존 계약대로 키와 실패 횟수를 함께 지운다.
private final class RepositoryKeyStore: CoreKeyStore, @unchecked Sendable {
    let keys: any MemoKeychain
    init(_ keys: any MemoKeychain) { self.keys = keys }
    private func call<T>(_ action: () throws -> T) throws -> T {
        do { return try action() }
        catch MemoLockError.damaged { throw CoreRepositoryError.Damaged }
        catch MemoLockError.keychain(let status) { throw CoreRepositoryError.Keychain(status: status) }
        catch { throw CoreRepositoryError.Keychain(status: -1) }
    }
    func readKey(id: String) throws -> Data? { try call { try keys.read(id: MemoID(rawValue: id)) } }
    func writeKey(id: String, bytes: Data) throws { try call { try keys.write(bytes, id: MemoID(rawValue: id)) } }
    func deleteKey(id: String) throws { try call { try keys.delete(id: MemoID(rawValue: id)) } }
    func readFailures(id: String) throws -> Int64 { try call { Int64(try keys.readFailures(id: MemoID(rawValue: id))) } }
    func writeFailures(id: String, failures: Int64) throws { try call { try keys.writeFailures(Int(failures), id: MemoID(rawValue: id)) } }
    func deleteFailures(id: String) throws {}
}

extension MemoDocument {
    var record: CoreMemoDocument { CoreMemoDocument(meta: meta.record, body: body, unknownFrontmatterLines: unknownFrontmatterLines, unknownLinkTokens: unknownLinkTokens) }
}
extension CoreMemoDocument {
    var native: MemoDocument { MemoDocument(meta: meta.native, body: body, unknownFrontmatterLines: unknownFrontmatterLines, unknownLinkTokens: unknownLinkTokens) }
}
extension MemoMeta {
    var record: CoreMemoMeta { CoreMemoMeta(
        schemaVersion: Int64(schemaVersion),
        id: id.rawValue,
        title: title,
        group: group,
        colorHex: colorHex,
        backgroundAlpha: backgroundAlpha,
        textAlpha: textAlpha,
        isOpen: isOpen,
        isPinned: isPinned,
        created: created.timeIntervalSinceReferenceDate,
        modified: modified.timeIntervalSinceReferenceDate,
        conflictOf: conflictOf?.rawValue,
        isLocked: isLocked,
        lockSalt: lockSalt,
        lockIterations: lockIterations.map(Int64.init),
        lockVersion: lockVersion.map(Int64.init),
        lockFailures: lockFailures.map(Int64.init),
        links: links.map { CoreMemoLink(to: $0.to.rawValue, kind: $0.kind.rawValue, label: $0.label, unknownSuffix: $0.unknownSuffix, preservesRawLabel: $0.preservesRawLabel) }) }
}
extension CoreMemoMeta {
    var native: MemoMeta {
        var m = MemoMeta(
            schemaVersion: Int(schemaVersion),
            id: MemoID(rawValue: id),
            title: title,
            group: group,
            colorHex: colorHex,
            backgroundAlpha: backgroundAlpha,
            textAlpha: textAlpha,
            isOpen: isOpen,
            isPinned: isPinned,
            created: Date(timeIntervalSinceReferenceDate: created),
            modified: Date(timeIntervalSinceReferenceDate: modified),
            conflictOf: conflictOf.map { MemoID(rawValue: $0) },
            links: links.map { l in
                var link = MemoLink(to: MemoID(rawValue: l.to), kind: MemoLinkKind(rawValue: l.kind)!, label: l.label, unknownSuffix: l.unknownSuffix)
                link.preservesRawLabel = l.preservesRawLabel
                return link
            }, isLocked: isLocked)
        m.lockSalt = lockSalt
        m.lockIterations = lockIterations.map(Int.init)
        m.lockVersion = lockVersion.map(Int.init)
        m.lockFailures = lockFailures.map(Int.init)
        return m
    }
}

/// FFI 버퍼는 호출 뒤 덮는다. 화면에서 받은 String 자체는 지울 수 없다.
final class RustPassword: @unchecked Sendable {
    private var bytes: Data
    init(_ password: String) {
        var utf8 = Array(password.utf8)
        defer { _ = utf8.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        bytes = Data(utf8)
    }
    func use<T>(_ action: (Data) throws -> T) rethrows -> T {
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try action(bytes)
    }
    deinit { bytes.resetBytes(in: 0..<bytes.count) }
}

final class RustPrivacyHook: CorePrivacyHook, @unchecked Sendable {
    let action: (MemoID) throws -> Void
    init(_ action: @escaping (MemoID) throws -> Void) { self.action = action }
    func beforeRemoval(id: String) throws {
        do { try action(MemoID(rawValue: id)) }
        catch { throw CoreRepositoryError.Io(message: error.localizedDescription) }
    }
}

/// 생성된 핸들은 이 객체를 통해서만 앱에서 사용한다.
final class RustLockBridge: @unchecked Sendable {
    let core: CoreLockStore
    init(core: CoreLockStore) { self.core = core }
    func call<T>(_ action: (CoreLockStore) throws -> T) throws -> T {
        do { return try action(core) }
        catch let error as CoreRepositoryError { throw RustMemoRepository.convert(error) }
    }
}

extension CoreDecryptedDocument {
    var native: MemoDocument { MemoDocument(meta: meta.native, body: body, unknownFrontmatterLines: unknownFrontmatterLines, unknownLinkTokens: unknownLinkTokens) }
}
