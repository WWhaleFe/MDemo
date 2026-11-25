import Foundation
import CryptoKit
import CryptoKit
import Observation

/// 앱 전체의 단일 진실 공급원 (설계서 §4-3).
///
/// 모든 상태 변경은 이곳을 거친다. UI가 저장소를 직접 호출하지 않는 이유는
/// 리스트 창과 스티키 창이 서로의 변경을 자동으로 보게 만들기 위해서다.
///
/// 메모리 원칙(§4-5): 이 객체가 들고 있는 것은 요약 목록뿐이다.
/// 본문은 `loadDocument(id:)`로 필요할 때 읽고, 창이 닫히면 호출자가 버린다.
@MainActor
@Observable
public final class MemoStore {
    public private(set) var summaries: [MemoSummary] = []
    /// 그룹 목록 (LST-02). 메모에 붙은 그룹 이름과 별개로 빈 그룹도 남길 수 있어야 한다.
    public private(set) var groups: [String] = []
    /// 휴지통 목록. 리스트 창에서 휴지통을 볼 때만 채운다 (TRS-02).
    public private(set) var trashed: [MemoSummary] = []

    /// 메모 내용과 별도로 저장하는 공유 배치 (설계서 §4).
    public private(set) var boardLayout: BoardLayout = .empty

    @ObservationIgnored public let keychain: any MemoKeychain
    @ObservationIgnored private var unlocking = Set<MemoID>()
    @ObservationIgnored private var lockSessions: [MemoID: MemoLockSession] = [:]
    @ObservationIgnored private let repository: any MemoRepository

    public init(repository: any MemoRepository, keychain: any MemoKeychain = DeviceMemoKeychain()) {
        self.keychain = keychain
        self.repository = repository
        summaries = (try? repository.loadSummaries()) ?? []
        reloadGroups()
        reloadBoardLayout()
    }

    public func reloadSummaries() {
        summaries = (try? repository.loadSummaries()) ?? []
        reloadBoardLayout()
    }

    public func reloadGroups() {
        let saved = (try? repository.loadGroups()) ?? []
        // 메모에는 붙어 있는데 목록에 없는 그룹도 보여야 한다 (다른 기기에서 만든 경우 등).
        let used = Set(summaries.compactMap(\.meta.group)).subtracting(saved)
        groups = saved + used.sorted()
    }

    public func reloadTrash() {
        trashed = (try? repository.loadTrashSummaries()) ?? []
    }

    // MARK: - 메모

    /// 새 메모를 만들고 파일로 저장한다 (KEY-10).
    @discardableResult
    public func createMemo(colorHex: String = MemoColor.presets[0].hex, group: String? = nil) -> MemoMeta {
        let meta = MemoMeta(id: .generate(), group: group, colorHex: colorHex)
        let document = MemoDocument(meta: meta, body: "")
        try? repository.save(document)
        summaries.insert(MemoSummary(meta: meta, preview: ""), at: 0)
        normalizeManualOrder()
        return meta
    }

    /// 잠기지 않은 메모를 첨부까지 복제한다. 성공한 새 ID만 입력 순서대로 돌려준다.
    @discardableResult
    public func duplicate(_ ids: [MemoID]) -> [MemoID] {
        var result: [MemoID] = []
        var seen = Set<MemoID>()
        var titles = Set(summaries.map(\.title))
        // 아직 저장하지 않은 보드 자리도 목록의 기본 배치와 같은 규칙으로 계산한다.
        var positions = boardLayout.placements
        let startY = positions.values.map { $0.y + 180 }.max() ?? 100
        var offset = 0
        for summary in summaries where positions[summary.id.rawValue] == nil {
            positions[summary.id.rawValue] = .init(
                x: 40 + Double(offset % 4) * 260, y: startY + Double(offset / 4) * 180)
            offset += 1
        }
        for id in ids where seen.insert(id).inserted {
            guard let index = summaries.firstIndex(where: { $0.id == id }),
                  var document = try? repository.load(id: id), !document.meta.isLocked else { continue }
            let newID = MemoID.generate()
            let now = Date()
            document.meta.id = newID
            document.meta.created = now
            document.meta.modified = now
            document.meta.isOpen = false
            document.meta.links = []
            document.meta.conflictOf = nil
            if let title = document.meta.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                let base = "\(title) 사본"
                var candidate = base
                var number = 2
                while titles.contains(candidate) {
                    candidate = "\(base) \(number)"
                    number += 1
                }
                document.meta.title = candidate
            }
            do {
                try repository.duplicate(id: id, as: document)
            } catch {
                continue
            }
            let summary = MemoSummary(meta: document.meta, preview: document.meta.isLocked ? "" : String(document.body.prefix(200)))
            titles.insert(summary.title)
            summaries.insert(summary, at: index + 1)
            if let position = positions[id.rawValue] {
                // 기본 자리도 함께 저장해 복제 뒤 원본이 다른 칸으로 밀리지 않게 한다.
                boardLayout.placements[id.rawValue] = position
                boardLayout.placements[newID.rawValue] = .init(x: position.x + 24, y: position.y + 24)
            }
            result.append(newID)
        }
        if !result.isEmpty {
            normalizeManualOrder()
            try? repository.saveBoardLayout(boardLayout)
        }
        return result
    }

    /// 밖에서 만든 문서를 그대로 들여온다 (DAT-07).
    public func importDocument(_ document: MemoDocument) {
        guard !document.meta.isLocked else { return }
        try? repository.save(document)
        summaries.insert(
            MemoSummary(meta: document.meta, preview: document.meta.isLocked ? "" : String(document.body.prefix(200))),
            at: 0
        )
    }

    /// 창을 열 때만 호출한다. 본문 전체를 읽는 유일한 경로다.
    public func loadDocument(id: MemoID) -> MemoDocument? {
        try? repository.load(id: id)
    }

    /// 메모의 첨부 이미지 폴더 (IMG-07).
    public func attachmentsDirectory(for id: MemoID) -> URL {
        repository.attachmentsDirectory(for: id)
    }

    /// 본문에서 쓰지 않는 첨부 파일 중 하루 넘게 지난 것을 지운다. 앱 시작 때 한 번 부른다.
    @discardableResult
    public func pruneUnusedAttachments(olderThanDays days: Int = 1) -> Int {
        repository.pruneUnusedAttachments(modifiedBefore: Date().addingTimeInterval(-Double(days) * 86_400))
    }

    /// 본문을 저장하고 요약을 갱신한다. 호출자가 디바운스한다 (DAT-03).
    @discardableResult
    public func saveBody(id: MemoID, body: String) -> Bool {
        guard var document = try? repository.load(id: id) else { return false }
        if document.meta.isLocked {
            var plaintext = Data(body.utf8)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            guard let session = lockSessions[id], let encrypted = try? session.seal(plaintext) else { return false }
            document.body = encrypted.base64EncodedString()
        } else {
            // 같은 내용이면 쓰지 않는다. 동기화로 받은 메모를 열린 창이 다시 읽어 그대로 저장하면
            // 수정 시각만 올라가 다음 동기화가 같은 내용을 되올리게 된다.
            if document.body == body { return true }
            document.body = body
        }
        document.meta.modified = MemoMeta.now()
        do { try repository.save(document) } catch { return false }
        updateSummary(meta: document.meta, preview: document.meta.isLocked ? "" : String(body.prefix(200)))
        return true
    }

    /// 메타데이터만 갱신한다 (색상·투명도·열림 상태 등).
    public func updateMeta(id: MemoID, _ transform: (inout MemoMeta) -> Void) {
        guard var document = try? repository.load(id: id) else { return }
        let before = document.meta
        transform(&document.meta)
        guard document.meta.isLocked == before.isLocked else { return }
        // 바뀐 것이 없으면 쓰지 않는다. 앱을 켤 때 열린 창마다 `open: true`를 다시 쓰며
        // 수정 시각이 올라가, 동기화가 내용 변화 없는 메모를 매번 올리고 두 기기에서 충돌 사본을 만들었다.
        guard document.meta != before else { return }
        document.meta.modified = MemoMeta.now()
        do { try repository.save(document) } catch { return }
        updateSummary(meta: document.meta, preview: document.meta.isLocked ? "" : String(document.body.prefix(200)))
    }

    /// 창 열림 상태를 기록한다. 이 값이 기기 간 미러링의 근거가 된다 (SYNC-08).
    public func setOpen(id: MemoID, isOpen: Bool) {
        updateMeta(id: id) { $0.isOpen = isOpen }
    }

    /// 재시작 시 다시 띄울 메모들 (WIN-06).
    public var openMemos: [MemoSummary] {
        summaries.filter { $0.meta.isOpen }
    }

    // MARK: - 보드 배치와 연결 (설계서 §4)

    public func reloadBoardLayout() {
        boardLayout = (try? repository.loadBoardLayout()) ?? .empty
        normalizeManualOrder()
    }

    public func setManualOrder(_ ids: [MemoID]) {
        boardLayout.manualOrder = ids
        boardLayout.manualOrder = boardLayout.normalizedOrder(among: summaries.map(\.id))
        try? repository.saveBoardLayout(boardLayout)
    }

    private func normalizeManualOrder() {
        let order = boardLayout.normalizedOrder(among: summaries.map(\.id))
        guard order != boardLayout.manualOrder else { return }
        boardLayout.manualOrder = order
        try? repository.saveBoardLayout(boardLayout)
    }

    public func setBoardPlacement(_ placement: BoardLayout.Placement, for id: MemoID) {
        setBoardPlacements([id: placement])
    }

    /// 자동 정리 결과를 한 번만 기록한다.
    public func setBoardPlacements(_ placements: [MemoID: BoardLayout.Placement]) {
        for (id, placement) in placements { boardLayout.placements[id.rawValue] = placement }
        try? repository.saveBoardLayout(boardLayout)
    }

    /// 되돌리기에서 아직 배치하지 않았던 카드 상태까지 복원한다.
    public func replaceBoardPlacements(_ placements: [String: BoardLayout.Placement]) {
        boardLayout.placements = placements
        try? repository.saveBoardLayout(boardLayout)
    }

    public func setBentoSpan(_ span: BoardLayout.BentoSpan?, for id: MemoID) {
        boardLayout.bentoSpans[id.rawValue] = span
        try? repository.saveBoardLayout(boardLayout)
    }

    /// 한 쌍에는 종류와 방향에 관계없이 연결 하나만 남긴다.
    public func link(from: MemoID, to: MemoID, kind: MemoLinkKind) {
        guard from != to, summaries.contains(where: { $0.id == from }),
              summaries.contains(where: { $0.id == to }) else { return }
        if summaries.first(where: { $0.id == to })?.meta.links.contains(where: { $0.to == from }) == true {
            updateMeta(id: to) { $0.links.removeAll { $0.to == from } }
        }
        let previous = summaries.first(where: { $0.id == from })?.meta.links.first(where: { $0.to == to })
        updateMeta(id: from) {
            $0.links.removeAll { $0.to == to }
            $0.links.append(MemoLink(to: to, kind: kind, label: previous?.label ?? "", unknownSuffix: previous?.unknownSuffix ?? ""))
        }
    }

    public func unlink(_ a: MemoID, _ b: MemoID) {
        for (source, target) in [(a, b), (b, a)] {
            if summaries.first(where: { $0.id == source })?.meta.links.contains(where: { $0.to == target }) == true {
                updateMeta(id: source) { $0.links.removeAll { $0.to == target } }
            }
        }
    }

    public var edges: [MemoEdge] {
        let ids = Set(summaries.map(\.id))
        var seen = Set<[String]>()
        var result: [MemoEdge] = []
        // 외부 파일의 중복도 한 쌍으로 합친다. ID순으로 골라 결과를 안정시킨다.
        for summary in summaries.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            for link in summary.meta.links where link.to != summary.id && ids.contains(link.to) {
                let pair = [summary.id.rawValue, link.to.rawValue].sorted()
                guard seen.insert(pair).inserted else { continue }
                result.append(MemoEdge(from: summary.id, to: link.to, kind: link.kind, label: link.label))
            }
        }
        return result
    }

    public func linkCount(of id: MemoID) -> Int {
        edges.count { $0.from == id || $0.to == id }
    }

    public var flows: [MemoFlow] {
        let metas = Dictionary(summaries.map { ($0.id, $0.meta) }, uniquingKeysWith: { first, _ in first })
        func createdBefore(_ a: MemoID, _ b: MemoID) -> Bool {
            if metas[a]!.created != metas[b]!.created { return metas[a]!.created < metas[b]!.created }
            return a.rawValue < b.rawValue
        }
        var adjacent: [MemoID: Set<MemoID>] = [:]
        var outgoing: [MemoID: [MemoID]] = [:]
        var incoming = Set<MemoID>()
        for edge in edges where edge.kind == .flow {
            adjacent[edge.from, default: []].insert(edge.to)
            adjacent[edge.to, default: []].insert(edge.from)
            outgoing[edge.from, default: []].append(edge.to)
            incoming.insert(edge.to)
        }
        var remaining = Set(adjacent.keys)
        var result: [MemoFlow] = []
        for seed in remaining.sorted(by: createdBefore) where remaining.contains(seed) {
            var component = Set<MemoID>()
            var pending = [seed]
            while let id = pending.popLast() {
                guard component.insert(id).inserted else { continue }
                pending.append(contentsOf: adjacent[id] ?? [])
            }
            remaining.subtract(component)
            guard component.count >= 2 else { continue }
            var visited = Set<MemoID>()
            var ordered: [MemoID] = []
            // 명시적 스택으로 깊이 우선 탐색해 긴 흐름에서도 호출 스택이 넘치지 않게 한다.
            func visit(_ start: MemoID) {
                var stack = [start]
                while let id = stack.popLast() {
                    guard visited.insert(id).inserted else { continue }
                    ordered.append(id)
                    stack.append(contentsOf: (outgoing[id] ?? []).sorted(by: createdBefore).reversed())
                }
            }
            for root in component.filter({ !incoming.contains($0) }).sorted(by: createdBefore) { visit(root) }
            // 시작점에서 닿지 못한 순환 메모는 생성순으로 뒤에 붙인다.
            ordered.append(contentsOf: component.subtracting(visited).sorted(by: createdBefore))
            result.append(MemoFlow(id: ordered[0], memoIDs: ordered))
        }
        return result.sorted {
            if metas[$0.id]!.modified != metas[$1.id]!.modified {
                return metas[$0.id]!.modified > metas[$1.id]!.modified
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    public func flow(containing id: MemoID) -> MemoFlow? {
        flows.first { $0.memoIDs.contains(id) }
    }

    // MARK: - 그룹 (LST-02, LST-03)

    public func createGroup(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !groups.contains(trimmed) else { return }
        groups.append(trimmed)
        try? repository.saveGroups(groups)
    }

    public func renameGroup(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, oldName != trimmed else { return }

        groups = groups.map { $0 == oldName ? trimmed : $0 }
        try? repository.saveGroups(groups)

        // 그 그룹에 속한 메모들의 이름표도 함께 바꾼다.
        for summary in summaries where summary.meta.group == oldName {
            updateMeta(id: summary.id) { $0.group = trimmed }
        }
    }

    /// 그룹만 지운다. 안에 있던 메모는 "그룹 없음"으로 남는다 — 메모를 잃지 않는 쪽을 택한다.
    public func deleteGroup(_ name: String) {
        groups.removeAll { $0 == name }
        try? repository.saveGroups(groups)

        for summary in summaries where summary.meta.group == name {
            updateMeta(id: summary.id) { $0.group = nil }
        }
    }

    public func assignGroup(_ group: String?, to id: MemoID) {
        updateMeta(id: id) { $0.group = group }
    }

    /// 그룹별 메모 개수. 목록 옆에 숫자를 보여 줄 때 쓴다.
    public func memoCount(inGroup group: String?) -> Int {
        guard let group else { return summaries.count }
        return summaries.count { $0.meta.group == group }
    }

    public var ungroupedCount: Int {
        summaries.count { $0.meta.group == nil }
    }

    // MARK: - 휴지통 (TRS-*)

    public func moveToTrash(id: MemoID) {
        moveToTrash(ids: [id])
    }

    /// 여러 개를 한 번에 버린다 (LST-05). 목록은 끝에 한 번만 다시 읽는다.
    public func moveToTrash(ids: [MemoID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            relock(id)
            try? repository.moveToTrash(id: id)
        }
        let removed = Set(ids)
        summaries.removeAll { removed.contains($0.id) }
        normalizeManualOrder()
        reloadTrash()
    }

    public func restoreFromTrash(id: MemoID) {
        restoreFromTrash(ids: [id])
    }

    public func restoreFromTrash(ids: [MemoID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            try? repository.restoreFromTrash(id: id)
        }
        reloadSummaries()
        reloadTrash()
    }

    public func permanentlyDelete(id: MemoID) {
        permanentlyDelete(ids: [id])
    }

    public func permanentlyDelete(ids: [MemoID]) {
        defer { onPrivacyChange?() }
        guard !ids.isEmpty else { return }
        var removed = Set<MemoID>()
        for id in ids {
            do {
                if trashed.first(where: { $0.id == id })?.meta.isLocked == true { try destroyMemo(id: id) }
                else { try repository.permanentlyDelete(id: id) }
                removed.insert(id)
            } catch {
                // 지우지 못한 메모의 연결은 복원을 위해 남긴다 (TRS-04).
                continue
            }
        }
        reloadSummaries()
        for summary in summaries where summary.meta.links.contains(where: { removed.contains($0.to) }) {
            updateMeta(id: summary.id) { $0.links.removeAll { removed.contains($0.to) } }
        }
        reloadTrash()
    }

    public func emptyTrash() {
        defer { onPrivacyChange?() }
        for memo in (try? repository.loadTrashSummaries()) ?? [] where memo.meta.isLocked { try? destroyMemo(id: memo.id) }
        try? repository.emptyTrash(deletedBefore: nil)
        reloadSummaries()
        reloadTrash()
    }

    /// 보관 기간이 지난 항목을 자동으로 비운다 (TRS-03). 앱 시작 시 한 번 호출한다.
    public func emptyTrash(olderThan days: Int) {
        defer { onPrivacyChange?() }
        guard days > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        for memo in (try? repository.loadTrashSummaries()) ?? [] where memo.meta.isLocked && (memo.deletedAt ?? .distantFuture) < cutoff { try? destroyMemo(id: memo.id) }
        try? repository.emptyTrash(deletedBefore: cutoff)
        reloadSummaries()
        reloadTrash()
    }

    // MARK: - 검색 (SRC-01, SRC-02)

    /// 그룹으로 좁힌 뒤 제목+본문에서 찾는다. 기존 호출을 위한 얇은 래퍼다.
    public func search(query: String, group: String? = nil, includeBodies: Bool = true) -> [MemoSummary] {
        filter(MemoSearch.filtered(summaries, group: group), query: query, target: includeBodies ? .titleAndBody : .title)
    }

    /// 요약 목록에서 검색어에 맞는 것만 남긴다. 입력 순서를 유지한다.
    ///
    /// 제목은 요약(목록에 보이는 제목 그대로)으로, 본문은 프론트매터를 뺀 파일 내용으로 찾는다.
    /// 본문 검색은 파일을 한 건씩 읽고 버린다. 본문 캐시는 두지 않는다 (§4-5).
    public func filter(_ summaries: [MemoSummary], query: String, target: MemoSearchTarget) -> [MemoSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return summaries }

        func titleMatches(_ summary: MemoSummary) -> Bool {
            summary.title.localizedCaseInsensitiveContains(needle)
        }
        switch target {
        case .title:
            return summaries.filter(titleMatches)
        case .body:
            let hits = (try? repository.searchBodies(matching: needle, in: summaries.map(\.id))) ?? []
            return summaries.filter { hits.contains($0.id) }
        case .titleAndBody:
            // 제목에서 걸린 메모는 파일을 다시 읽지 않는다.
            let titleHits = Set(summaries.filter(titleMatches).map(\.id))
            let remaining = summaries.filter { !titleHits.contains($0.id) }.map(\.id)
            let bodyHits = remaining.isEmpty ? [] : ((try? repository.searchBodies(matching: needle, in: remaining)) ?? [])
            return summaries.filter { titleHits.contains($0.id) || bodyHits.contains($0.id) }
        }
    }

    public func lockFailureCount(id: MemoID) -> Int {
        max(summaries.first(where: { $0.id == id })?.meta.lockFailures ?? 0, (try? keychain.readFailures(id: id)) ?? 0)
    }

    public func lockSession(for id: MemoID) -> MemoLockSession? { lockSessions[id] }

    public func relock(_ id: MemoID) {
        lockSessions.removeValue(forKey: id)?.clear()
        if let meta = summaries.first(where: { $0.id == id })?.meta { updateSummary(meta: meta, preview: "") }
    }

    public func decryptedDocument(id: MemoID) throws -> MemoDocument {
        var document = try repository.load(id: id)
        guard document.meta.isLocked else { return document }
        guard let session = lockSessions[id], let cipher = Data(base64Encoded: document.body) else { throw MemoLockError.locked }
        var plain = try session.open(cipher)
        defer { plain.resetBytes(in: 0..<plain.count) }
        guard let body = String(data: plain, encoding: .utf8) else { throw MemoLockError.damaged }
        document.body = body
        return document
    }

    /// 무거운 키 유도는 호출자가 백그라운드에서 수행한다. 실패 횟수 기록은 메인에서 직렬화한다.
    public func unlock(id: MemoID, password: String) async throws {
        guard LockCrypto.validPassword(password) else { throw MemoLockError.wrongPassword }
        guard unlocking.insert(id).inserted else { throw MemoLockError.locked }
        defer { unlocking.remove(id) }
        var document = try repository.load(id: id)
        guard document.meta.isLocked, document.meta.lockVersion == 1,
              let salt = document.meta.lockSalt.flatMap({ Data(base64Encoded: $0) }),
              let iterations = document.meta.lockIterations else { throw MemoLockError.damaged }
        let failures = max(document.meta.lockFailures ?? 0, try keychain.readFailures(id: id))
        if failures >= 10 { try destroyMemo(id: id); throw MemoLockError.destroyed }
        guard let wrapped = try keychain.read(id: id) else { throw MemoLockError.missingKey }
        // 결과가 나오기 전에 시도를 기록한다. 인증 성공이나 본문 손상 때 아래에서 복구한다.
        guard salt.count == 16, (LockCrypto.minimumIterations...20_000_000).contains(iterations), wrapped.count >= 28 else { throw MemoLockError.damaged }
        try keychain.writeFailures(failures + 1, id: id)
        var key: Data
        do {
            key = try await Task.detached(priority: .userInitiated) {
                var kek = try LockCrypto.derive(password: password, salt: salt, iterations: iterations)
                defer { kek.resetBytes(in: 0..<kek.count) }
                do { return try LockCrypto.open(wrapped, key: kek, context: id.rawValue + "/key") }
                catch CryptoKitError.authenticationFailure { throw MemoLockError.wrongPassword }
            }.value
        } catch MemoLockError.wrongPassword {
            document = try repository.load(id: id)
            document.meta.lockFailures = failures + 1
            try repository.save(document)
            updateSummary(meta: document.meta, preview: "")
            if document.meta.lockFailures! >= 10 { try destroyMemo(id: id); throw MemoLockError.destroyed }
            throw MemoLockError.wrongPassword
        } catch {
            try keychain.writeFailures(failures, id: id)
            throw error
        }
        defer { key.resetBytes(in: 0..<key.count) }
        try keychain.writeFailures(failures, id: id)
        try Task.checkCancellation()
        document = try repository.load(id: id)
        let session = MemoLockSession(id: id, key: key)
        var installed = false
        defer { if !installed { session.clear() } }
        guard let cipher = Data(base64Encoded: document.body) else { session.clear(); throw MemoLockError.damaged }
        do {
            var verification = try session.open(cipher)
            defer { verification.resetBytes(in: 0..<verification.count) }
            guard String(data: verification, encoding: .utf8) != nil else { throw MemoLockError.damaged }
        } catch {
            session.clear()
            throw MemoLockError.damaged
        }
        document.meta.lockFailures = 0
        try keychain.writeFailures(0, id: id)
        try repository.save(document)
        lockSessions[id]?.clear()
        lockSessions[id] = session
        installed = true
        updateSummary(meta: document.meta, preview: "")
    }

    /// 새 ID에는 첫 기록부터 암호문만 쓴다. 원본은 검증 완료 전에는 건드리지 않는다.
    @discardableResult
    public func createLockedMemo(password: String, moving source: MemoID? = nil) async throws -> MemoID {
        guard LockCrypto.validPassword(password) else { throw MemoLockError.invalidPassword }
        let original = try source.map { try repository.load(id: $0) }
        guard original?.meta.isLocked != true else { throw MemoLockError.locked }
        var document = original ?? MemoDocument(meta: MemoMeta(id: .generate()), body: "")
        document.meta.id = .generate()
        let id = document.meta.id
        // 직접 붙인 제목만 가져온다. 제목이 없는 메모의 "보이는 제목"은 본문 첫 줄이라,
        // 그것을 평문 제목으로 적으면 본문 일부가 암호 밖으로 새어 나간다.
        document.meta.title = original.flatMap { $0.meta.title?.trimmingCharacters(in: .whitespaces).isEmpty == false ? $0.meta.title : nil }
        document.meta.created = MemoMeta.now()
        document.meta.modified = MemoMeta.now()
        document.meta.links = []
        document.meta.conflictOf = nil
        document.unknownLinkTokens = []
        document.meta.isLocked = true
        document.meta.isOpen = true
        document.meta.lockSalt = try LockCrypto.random(count: 16).base64EncodedString()
        document.meta.lockIterations = LockCrypto.calibratedIterations()
        document.meta.lockVersion = 1
        document.meta.lockFailures = 0
        let salt = Data(base64Encoded: document.meta.lockSalt!)!
        let iterations = document.meta.lockIterations!
        let session = try MemoLockSession(id: id, key: LockCrypto.random(count: 32))
        var attachmentHashes: [String: Data] = [:]
        do {
            let wrapped = try await Task.detached(priority: .userInitiated) {
                try session.wrapped(password: password, salt: salt, iterations: iterations)
            }.value
            try keychain.write(wrapped, id: id)
            let privacyRoot = repository.attachmentsDirectory(for: id).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try MemoPrivacyLedger.insert(id, name: "local-only", root: privacyRoot)
            document.body = try session.seal(Data(document.body.utf8)).base64EncodedString()
            try repository.save(document)
            try FileManager.default.createDirectory(at: repository.attachmentsDirectory(for: id), withIntermediateDirectories: true)
            if let source {
                let from = repository.attachmentsDirectory(for: source)
                let to = repository.attachmentsDirectory(for: id)
                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
                let files = FileManager.default.fileExists(atPath: from.path)
                    ? try FileManager.default.contentsOfDirectory(at: from, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) : []
                for file in files {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MemoLockError.damaged }
                    var plain = try Data(contentsOf: file)
                    defer { plain.resetBytes(in: 0..<plain.count) }
                    attachmentHashes[file.lastPathComponent] = Data(SHA256.hash(data: plain))
                    let cipher = try session.seal(plain, name: file.lastPathComponent)
                    try cipher.write(to: to.appendingPathComponent(file.lastPathComponent + ".enc"), options: .atomic)
                    var verified = try session.open(Data(contentsOf: to.appendingPathComponent(file.lastPathComponent + ".enc")), name: file.lastPathComponent)
                    guard verified == plain else { throw MemoLockError.damaged }
                    verified.resetBytes(in: 0..<verified.count)
                }
            }
            if let source, try repository.load(id: source) != original { throw MemoLockError.damaged }
            try SecureMemoDeletion.synchronize(repository.attachmentsDirectory(for: id).deletingLastPathComponent())
            let saved = try repository.load(id: id)
            guard let persisted = try keychain.read(id: id) else { throw MemoLockError.missingKey }
            let reopened = try await Task.detached(priority: .userInitiated) {
                var kek = try LockCrypto.derive(password: password, salt: salt, iterations: iterations)
                defer { kek.resetBytes(in: 0..<kek.count) }
                var key = try LockCrypto.open(persisted, key: kek, context: id.rawValue + "/key")
                defer { key.resetBytes(in: 0..<key.count) }
                return MemoLockSession(id: id, key: key)
            }.value
            defer { reopened.clear() }
            var verified = try reopened.open(Data(base64Encoded: saved.body)!)
            defer { verified.resetBytes(in: 0..<verified.count) }
            guard verified == Data((original?.body ?? "").utf8) else { throw MemoLockError.damaged }
            for (name, hash) in attachmentHashes {
                var bytes = try reopened.open(Data(contentsOf: repository.attachmentsDirectory(for: id).appendingPathComponent(name + ".enc")), name: name)
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                guard Data(SHA256.hash(data: bytes)) == hash else { throw MemoLockError.damaged }
            }
            if let source {
                guard try repository.load(id: source) == original else { throw MemoLockError.damaged }
                let from = repository.attachmentsDirectory(for: source)
                let files = FileManager.default.fileExists(atPath: from.path)
                    ? try FileManager.default.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) : []
                guard Set(files.map(\.lastPathComponent)) == Set(attachmentHashes.keys) else { throw MemoLockError.damaged }
                for file in files {
                    var bytes = try Data(contentsOf: file)
                    defer { bytes.resetBytes(in: 0..<bytes.count) }
                    guard Data(SHA256.hash(data: bytes)) == attachmentHashes[file.lastPathComponent] else { throw MemoLockError.damaged }
                }
            }
        } catch {
            session.clear()
            try? keychain.delete(id: id)
            try? SecureMemoDeletion.remove(repository.attachmentsDirectory(for: id).deletingLastPathComponent())
            throw error
        }
        lockSessions[id] = session
        updateSummary(meta: document.meta, preview: "")
        if let source { try destroyMemo(id: source) }
        return id
    }

    public func changePassword(id: MemoID, password: String) async throws {
        guard LockCrypto.validPassword(password) else { throw MemoLockError.invalidPassword }
        guard let session = lockSessions[id] else { throw MemoLockError.locked }
        guard let previous = try keychain.read(id: id) else { throw MemoLockError.missingKey }
        let salt = try LockCrypto.random(count: 16)
        let iterations = LockCrypto.calibratedIterations()
        let wrapped = try await Task.detached(priority: .userInitiated) { try session.wrapped(password: password, salt: salt, iterations: iterations) }.value
        var document = try repository.load(id: id)
        try keychain.write(wrapped, id: id)
        document.meta.lockSalt = salt.base64EncodedString()
        document.meta.lockIterations = iterations
        do { try repository.save(document) }
        catch {
            try keychain.write(previous, id: id)
            throw error
        }
        updateSummary(meta: document.meta, preview: "")
    }

    @discardableResult
    public func moveToPlainMemo(id: MemoID) throws -> MemoID {
        var document = try decryptedDocument(id: id)
        guard document.meta.isLocked, let session = lockSessions[id] else { throw MemoLockError.locked }
        let newID = MemoID.generate()
        document.meta.id = newID
        document.meta.isLocked = false
        document.meta.lockSalt = nil; document.meta.lockIterations = nil
        document.meta.lockVersion = nil; document.meta.lockFailures = nil
        document.meta.links = []
        document.meta.created = MemoMeta.now(); document.meta.modified = MemoMeta.now()
        do {
            try repository.save(document)
            let to = repository.attachmentsDirectory(for: newID)
            try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(at: repository.attachmentsDirectory(for: id), includingPropertiesForKeys: nil) where file.pathExtension == "enc" {
                let name = file.deletingPathExtension().lastPathComponent
                var plain = try session.open(Data(contentsOf: file), name: name)
                defer { plain.resetBytes(in: 0..<plain.count) }
                try plain.write(to: to.appendingPathComponent(name), options: .atomic)
                var verified = try Data(contentsOf: to.appendingPathComponent(name))
                defer { verified.resetBytes(in: 0..<verified.count) }
                guard verified == plain else { throw MemoLockError.damaged }
            }
            try SecureMemoDeletion.synchronize(repository.attachmentsDirectory(for: newID).deletingLastPathComponent())
            guard try repository.load(id: newID).body == document.body else { throw MemoLockError.damaged }
            for file in try FileManager.default.contentsOfDirectory(at: repository.attachmentsDirectory(for: id), includingPropertiesForKeys: nil) where file.pathExtension == "enc" {
                let name = file.deletingPathExtension().lastPathComponent
                var plain = try session.open(Data(contentsOf: file), name: name)
                defer { plain.resetBytes(in: 0..<plain.count) }
                guard try Data(contentsOf: to.appendingPathComponent(name)) == plain else { throw MemoLockError.damaged }
            }
        } catch {
            try? SecureMemoDeletion.remove(repository.attachmentsDirectory(for: newID).deletingLastPathComponent())
            throw error
        }
        updateSummary(meta: document.meta, preview: document.meta.isLocked ? "" : String(document.body.prefix(200)))
        try destroyMemo(id: id)
        return newID
    }

    /// 열쇠 삭제, 묘비 기록, 덮어쓰기 순서를 지킨다. 실패한 삭제는 묘비로 다음 동기화에서 재시도한다.
    @ObservationIgnored public var onPrivacyChange: (() -> Void)?
    /// 파기 실패를 재현하는 검증용 주입 지점이다.
    @ObservationIgnored public var beforePrivacyRemoval: ((MemoID) throws -> Void)?

    public func destroyMemo(id: MemoID) throws {
        try keychain.delete(id: id)
        relock(id)
        let root = repository.attachmentsDirectory(for: id).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try MemoPrivacyLedger.insert(id, name: "destroyed", root: root)
        defer { onPrivacyChange?() }
        try beforePrivacyRemoval?(id)
        try SecureMemoDeletion.removeCopies(id: id, root: root)
        try repository.permanentlyDelete(id: id)
        summaries.removeAll { $0.id == id }
        for summary in summaries where summary.meta.links.contains(where: { $0.to == id }) {
            updateMeta(id: summary.id) { $0.links.removeAll { $0.to == id } }
        }
        boardLayout.placements[id.rawValue] = nil
        boardLayout.bentoSpans[id.rawValue] = nil
        normalizeManualOrder()
        try repository.saveBoardLayout(boardLayout)
        reloadTrash()
    }

    private func updateSummary(meta: MemoMeta, preview: String) {
        let summary = MemoSummary(meta: meta, preview: preview)
        if let index = summaries.firstIndex(where: { $0.id == meta.id }) {
            summaries[index] = summary
        } else {
            summaries.append(summary)
        }
    }
}
