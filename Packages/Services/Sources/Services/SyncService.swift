import CryptoKit
import Foundation
import MemoCore

/// 데이터 폴더와 "원격" 폴더 사이에서 메모를 비교하고 복사하는 동기화 엔진 (SYNC-01~06).
///
/// 원격 폴더는 구글 드라이브의 거울 폴더다(`DriveMirrorSync`가 드라이브와 거울을 맞춘다).
/// 예전에는 iCloud Drive 폴더를 원격으로 썼지만, Windows판이 쓸 수 없어 구글 드라이브만 남겼다.
///
/// **작업 데이터는 늘 로컬에 둔다**: 원격 폴더를 직접 작업 폴더로 쓰면
/// 아직 내려받지 않은 파일이나 동기화 지연이 편집 경로에 끼어든다.
public struct SyncReport: Sendable, Equatable {
    public init() {}
    /// 내 것을 원격으로 올린 메모 수.
    public var pushed = 0
    /// 원격 것을 내려받은 메모 수.
    public var pulled = 0
    /// 양쪽이 모두 바뀌어 사본을 남긴 메모 수 (SYNC-06).
    public var conflicts = 0
    /// 삭제가 전파된 메모 수.
    public var deletions = 0
    /// 프론트매터가 깨져 받지 않고 건너뛴 파일 수.
    public var unreadable = 0
    public var lockedLocal = 0
    public var removedLocalOnly = 0
    /// 이번에 새로 만든 충돌 사본. 같은 회차 안에 반대쪽으로 올리는 데 쓴다.
    var conflictCopies: [MemoID] = []

    public var isEmpty: Bool {
        pushed == 0 && pulled == 0 && conflicts == 0 && deletions == 0 && unreadable == 0 && removedLocalOnly == 0
    }

    public var summary: String {
        guard !isEmpty || lockedLocal > 0 || removedLocalOnly > 0 else { return "변경 없음" }
        var parts: [String] = []
        if pushed > 0 { parts.append("올림 \(pushed)") }
        if pulled > 0 { parts.append("내려받음 \(pulled)") }
        if deletions > 0 { parts.append("삭제 반영 \(deletions)") }
        if conflicts > 0 { parts.append("충돌 사본 \(conflicts)") }
        if unreadable > 0 { parts.append("읽지 못한 파일 \(unreadable)") }
        if lockedLocal > 0 { parts.append("잠긴 메모 \(lockedLocal)개는 이 맥에만 있습니다") }
        if removedLocalOnly > 0 { parts.append("다른 맥에서 잠근 메모 \(removedLocalOnly)개를 이 맥에서 지웠습니다") }
        return parts.joined(separator: " · ")
    }
}

public enum SyncMode: Sendable {
    /// 양방향. 자동 동기화가 쓴다.
    case both
    /// 내 변경만 올린다 (앱을 끄기 직전, SYNC-02).
    case push
    /// 원격 변경만 내려받는다 (SYNC-03).
    case pull
}

/// 훑은 뒤 파일이 바뀌어 이번 동기화에서는 그 메모를 건드리지 않기로 했다는 표시.
private struct SkipThisRound: Error {}

public struct SyncService: Sendable {
    public let localRoot: URL
    public let remoteRoot: URL
    /// 마지막으로 맞춰 둔 시각을 메모별로 적어 둔다. 기기마다 따로 갖는다.
    private let keychain: any MemoKeychain
    private let stateURL: URL
    /// 시험용: 폴더를 훑은 직후, 반영하기 직전에 불린다. 그 사이 다른 쪽이 바뀌는 경쟁 상황을 흉내 낸다.
    public var afterScan: (@Sendable () -> Void)?

    private static let memosFolder = "memos"
    private static let trashFolder = "trash"
    private static let memoFileName = "memo.md"
    private static let groupsFileName = "groups.json"
    private static let boardFileName = "board.json"

    public init(localRoot: URL, remoteRoot: URL, stateURL: URL, keychain: any MemoKeychain = DeviceMemoKeychain()) {
        self.keychain = keychain
        self.localRoot = localRoot
        self.remoteRoot = remoteRoot
        self.stateURL = stateURL
    }

    /// iCloud Drive 최상위 폴더. 꺼져 있으면 nil.
    /// 동기화에는 더 쓰지 않는다. 예전 판 데이터를 옮겨 올 때(LegacyMigration)만 본다.
    public static func iCloudDriveRoot() -> URL? {
        let iCloudDrive = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: iCloudDrive.path) ? iCloudDrive : nil
    }

    // MARK: - 동기화

    public func sync(mode: SyncMode = .both) throws -> SyncReport {
        try prepareFolders()

        var state = loadState()
        var report = SyncReport()

        let excluded = try applyPrivacy(report: &report)
        let destroyed = excluded.destroyed
        let localOnly = excluded.localOnly
        for raw in destroyed.union(localOnly) { state.forget(raw) }
        let localScan = scan(root: localRoot)
        let remoteScan = scan(root: remoteRoot)
        let local = localScan.entries
        let remote = remoteScan.entries
        // 읽지 못한 파일은 건드리지 않는다. 없는 것으로 보고 반대편 것으로 덮으면 안 된다.
        let skipped = localScan.unreadable.union(remoteScan.unreadable)
        report.unreadable = skipped.count
        afterScan?()

        for id in Set(local.keys).union(remote.keys) where !skipped.contains(id) && !destroyed.contains(id.rawValue) && !localOnly.contains(id.rawValue) {
            do {
                try reconcile(
                    id: id,
                    local: local[id],
                    remote: remote[id],
                    mode: mode,
                    state: &state,
                    report: &report
                )
            } catch is SkipThisRound {
                // 훑은 뒤 파일이 바뀌었다. 덮어쓰지 않고 이 메모는 다음 동기화에서 맞춘다.
                continue
            }
        }

        // 충돌 사본은 이쪽 기기에만 만들어진다. 다음 회차를 기다리지 않고 바로 반대쪽에도 올린다.
        // 안 그러면 구글 드라이브처럼 거울을 거치는 곳에서는 이 기기가 한 번 더 맞출 때까지 다른 기기가 사본을 못 본다.
        if mode != .pull, !report.conflictCopies.isEmpty {
            let fresh = scan(root: localRoot).entries
            for id in report.conflictCopies {
                guard let entry = fresh[id] else { continue }
                try? reconcile(id: id, local: entry, remote: nil, mode: mode, state: &state, report: &report)
            }
        }

        try mergeGroups(mode: mode)
        try syncBoard(mode: mode, state: &state)
        saveState(state)
        return report
    }

    /// 자동 동기화가 꺼져 있어도 원본 파기와 로컬 전용 삭제 기록은 즉시 반영한다.
    public func enforcePrivacy() throws -> SyncReport {
        try prepareFolders()
        var report = SyncReport()
        _ = try applyPrivacy(report: &report)
        return report
    }

    private func applyPrivacy(report: inout SyncReport) throws -> (destroyed: Set<String>, localOnly: Set<String>) {
        // 개인정보 삭제 기록은 방향 설정과 무관하게 먼저 합친다.
        let destroyed = try MemoPrivacyLedger.read("destroyed", root: localRoot).union(MemoPrivacyLedger.read("destroyed", root: remoteRoot))
        var localOnly = try MemoPrivacyLedger.read("local-only", root: localRoot).union(MemoPrivacyLedger.read("local-only", root: remoteRoot))
        let privacyRepository = try FileMemoRepository(rootDirectory: localRoot)
        let localLocked = try (privacyRepository.loadSummaries() + privacyRepository.loadTrashSummaries()).filter { $0.meta.isLocked }
        localOnly.formUnion(localLocked.map { $0.id.rawValue })
        for (name, ids) in [("destroyed", destroyed), ("local-only", localOnly)] {
            try MemoPrivacyLedger.write(ids, name: name, root: localRoot)
            try MemoPrivacyLedger.write(ids, name: name, root: remoteRoot)
        }
        report.lockedLocal = localLocked.count
        for raw in destroyed.union(localOnly) {
            let id = MemoID(rawValue: raw)
            try SecureMemoDeletion.removeCopies(id: id, root: remoteRoot)
            let lockedHere = localLocked.contains { $0.id == id }
            if destroyed.contains(raw) || !lockedHere {
                let exists = ["memos", "trash"].contains { FileManager.default.fileExists(atPath: localRoot.appendingPathComponent($0).appendingPathComponent(raw).path) }
                if destroyed.contains(raw) { try keychain.delete(id: id) }
                try SecureMemoDeletion.removeCopies(id: id, root: localRoot)
                if exists {
                    if destroyed.contains(raw) { report.deletions += 1 }
                    else { report.removedLocalOnly += 1 }
                }
            }
        }
        return (destroyed, localOnly)
    }

    /// 한 메모에 대해 무엇을 할지 정하고 실행한다.
    ///
    /// 판단 기준은 "지난번 맞췄을 때와 달라졌는가"다.
    /// 지문(내용 SHA-256)이 기록돼 있으면 지문으로, 없으면(이전 형식 상태 파일) 프론트매터 `modified`로 본다.
    /// 양쪽 다 달라졌으면 최신본을 남기고 진 쪽은 사본으로 보존한다 - 어느 쪽도 버리지 않는다.
    private func reconcile(
        id: MemoID,
        local: Entry?,
        remote: Entry?,
        mode: SyncMode,
        state: inout SyncState,
        report: inout SyncReport
    ) throws {
        let lastSynced = state.dates[id.rawValue]
        let lastHashes = state.hashes[id.rawValue]

        switch (local, remote) {
        case (nil, nil):
            state.forget(id.rawValue)

        case (let localEntry?, nil):
            // 이 기기에서 새로 만들었거나, 저쪽에서 아예 사라진 경우다.
            // 사라진 쪽은 지우지 않고 다시 올린다 - 파일이 사라지는 경우는 원인이 다양해서, 되살리는 쪽이 안전하다.
            guard mode != .pull else { return }
            try transfer(id: id, from: localRoot, to: remoteRoot, entry: localEntry, replacing: nil, state: &state)
            report.pushed += 1

        case (nil, let remoteEntry?):
            guard mode != .push else { return }
            try transfer(id: id, from: remoteRoot, to: localRoot, entry: remoteEntry, replacing: nil, state: &state)
            report.pulled += 1

        case (var localEntry?, var remoteEntry?):
            // 한쪽이 휴지통에 있으면 삭제로 본다. 삭제는 어느 쪽이든 따라간다 (TRS-01).
            if localEntry.isInTrash != remoteEntry.isInTrash {
                try propagateTrashState(
                    id: id,
                    local: localEntry,
                    remote: remoteEntry,
                    mode: mode,
                    lastSynced: lastSynced,
                    lastHashes: lastHashes,
                    state: &state,
                    report: &report
                )
                return
            }

            let localChanged = hasChanged(localEntry, lastSynced: lastSynced, lastHashes: lastHashes)
            let remoteChanged = hasChanged(remoteEntry, lastSynced: lastSynced, lastHashes: lastHashes)

            // 다른 앱에서 고친 파일은 `modified`가 그대로다. 파일 수정 시각으로 대신 판단한다.
            // 파일에 고쳐 쓰는 것은 실제로 보내기 직전(`transfer`)에 한다. 충돌 사본을 뜨기 전에는 아무것도 덮어쓰지 않는다.
            localEntry.isExternal = localChanged && isExternalEdit(localEntry, lastSynced: lastSynced, lastHashes: lastHashes)
            remoteEntry.isExternal = remoteChanged && isExternalEdit(remoteEntry, lastSynced: lastSynced, lastHashes: lastHashes)
            if localEntry.isExternal {
                localEntry.modified = localEntry.fileModified ?? Date()
            }
            if remoteEntry.isExternal {
                remoteEntry.modified = remoteEntry.fileModified ?? Date()
            }

            // 지문이 같으면 내용이 같은 것이다.
            if localChanged || remoteChanged, localEntry.hash == remoteEntry.hash {
                state.record(id.rawValue, date: localEntry.modified, hashes: [localEntry.hash, remoteEntry.hash])
                return
            }

            // 이전 형식 상태 파일은 지문이 없다. 바뀌지 않았다면 지금 지문을 기록해 다음부터 지문으로 판단한다.
            // 단, 시각은 같은데 내용이 다르면(바깥 편집) 같은 상태로 확정하지 않고 충돌로 둘 다 남긴다.
            if lastHashes == nil, !localChanged, !remoteChanged {
                if localEntry.hash == remoteEntry.hash {
                    state.record(id.rawValue, date: lastSynced ?? localEntry.modified, hashes: [localEntry.hash, remoteEntry.hash])
                } else {
                    try resolveConflict(
                        id: id, local: localEntry, remote: remoteEntry,
                        mode: mode, state: &state, report: &report
                    )
                }
                return
            }

            switch (localChanged, remoteChanged) {
            case (false, false):
                break

            case (true, false):
                guard mode != .pull else { return }
                try transfer(id: id, from: localRoot, to: remoteRoot, entry: localEntry, replacing: remoteEntry, state: &state)
                report.pushed += 1

            case (false, true):
                guard mode != .push else { return }
                try transfer(id: id, from: remoteRoot, to: localRoot, entry: remoteEntry, replacing: localEntry, state: &state)
                report.pulled += 1

            case (true, true):
                // 지문이 같은 경우는 위에서 이미 걸렀다. 여기까지 왔으면 내용이 다르다.
                try resolveConflict(
                    id: id,
                    local: localEntry,
                    remote: remoteEntry,
                    mode: mode,
                    state: &state,
                    report: &report
                )
            }
        }
    }

    /// 지난번 맞춘 뒤로 바뀌었는가.
    private func hasChanged(_ entry: Entry, lastSynced: Date?, lastHashes: [String]?) -> Bool {
        if let lastHashes { return !lastHashes.contains(entry.hash) }
        return !isSameMoment(entry.modified, lastSynced)
    }

    /// 내용은 바뀌었는데 `modified`는 지난번 맞춘 시각에서 나아가지 않았다면 다른 앱에서 고친 것이다.
    func isExternalEdit(_ entry: Entry, lastSynced: Date?, lastHashes: [String]?) -> Bool {
        guard lastHashes != nil, let lastSynced else { return false }
        return entry.modified.timeIntervalSince1970 <= lastSynced.timeIntervalSince1970 + 0.0005
    }

    /// 바깥에서 고쳐진 파일의 프론트매터 `modified`를 `entry.modified`(파일 수정 시각)로 고쳐 쓴다.
    /// 훑은 뒤 파일이 바뀌었으면 쓰지 않고 이번 회차를 건너뛴다.
    private func stampModified(id: MemoID, root: URL, entry: Entry) throws -> Entry {
        try expect(id: id, root: root, inTrash: entry.isInTrash, hash: entry.hash)
        var document = try readDocument(id: id, root: root, inTrash: entry.isInTrash)
        document.meta.modified = entry.modified
        try writeDocument(document, root: root, inTrash: entry.isInTrash)
        var result = entry
        result.hash = Self.fingerprint(of: memoFileURL(id: id, root: root, inTrash: entry.isInTrash)) ?? entry.hash
        result.isExternal = false
        return result
    }

    /// 지금 디스크의 memo.md 지문이 훑었을 때와 같은지 본다. `hash`가 nil이면 파일이 없어야 한다.
    private func expect(id: MemoID, root: URL, inTrash: Bool, hash: String?) throws {
        let current = Self.fingerprint(of: memoFileURL(id: id, root: root, inTrash: inTrash))
        guard current == hash else { throw SkipThisRound() }
    }

    /// 받는 쪽이 훑었을 때와 같은지 본다. `existing`이 있으면 그 자리의 지문이, 없으면 두 자리 모두 비어 있어야 한다.
    private func expectDestination(id: MemoID, root: URL, existing: Entry?) throws {
        for inTrash in [false, true] {
            let hash = (existing?.isInTrash == inTrash) ? existing?.hash : nil
            try expect(id: id, root: root, inTrash: inTrash, hash: hash)
        }
    }

    /// 한쪽의 메모를 반대편으로 복사하고 맞춘 기록을 남긴다.
    ///
    /// 쓰기 직전에 보내는 쪽과 받는 쪽 지문을 다시 확인한다. 훑은 뒤 바뀌었으면 덮어쓰지 않고 건너뛴다.
    /// 바깥에서 고쳐 들어온 것이면 `modified`를 바로잡아 저장한다. 이 경우 보낸 쪽과 받은 쪽 지문이 달라지므로
    /// 둘 다 "맞춘 지문"으로 기록해 되돌아 복사되지 않게 한다.
    private func transfer(
        id: MemoID, from source: URL, to destination: URL, entry: Entry, replacing existing: Entry?, state: inout SyncState
    ) throws {
        var entry = entry
        try expect(id: id, root: source, inTrash: entry.isInTrash, hash: entry.hash)
        try expectDestination(id: id, root: destination, existing: existing)
        // 내 쪽 파일이 보내는 쪽이면 그 자리에서 `modified`를 고쳐 둔다(목록 정렬이 맞도록).
        if entry.isExternal, source == localRoot {
            entry = try stampModified(id: id, root: source, entry: entry)
        }

        try copyMemo(id: id, from: source, to: destination, inTrash: entry.isInTrash)
        var hashes = [entry.hash]
        if entry.isExternal {
            var document = try readDocument(id: id, root: destination, inTrash: entry.isInTrash)
            document.meta.modified = entry.modified
            try writeDocument(document, root: destination, inTrash: entry.isInTrash)
        }
        if let received = Self.fingerprint(of: memoFileURL(id: id, root: destination, inTrash: entry.isInTrash)) {
            hashes.append(received)
        }
        state.record(id.rawValue, date: entry.modified, hashes: hashes)
    }

    /// 양쪽이 모두 바뀐 경우 (SYNC-06).
    ///
    /// 최신본을 정본으로 삼고, 진 쪽은 새 ID를 붙인 사본으로 남긴다.
    /// 사본에는 첨부를 포함한 메모 폴더 전체가 담기며, 무엇이든 덮어쓰기 전에 먼저 만든다.
    /// 리스트 창이 `conflictOf` 표시를 보고 사용자에게 알려 준다.
    private func resolveConflict(
        id: MemoID,
        local: Entry,
        remote: Entry,
        mode: SyncMode,
        state: inout SyncState,
        report: inout SyncReport
    ) throws {
        // 시각이 같으면 파일 수정 시각으로 가른다.
        let remoteIsNewer = remote.modified > local.modified
            || (isSameMoment(remote.modified, local.modified)
                && (remote.fileModified ?? .distantPast) > (local.fileModified ?? .distantPast))
        if remoteIsNewer {
            guard mode != .push else { return }
        } else {
            guard mode != .pull else { return }
        }

        // 훑은 뒤 바뀌었으면 사본도 만들지 않고 건너뛴다.
        try expect(id: id, root: localRoot, inTrash: local.isInTrash, hash: local.hash)
        try expect(id: id, root: remoteRoot, inTrash: remote.isInTrash, hash: remote.hash)

        // 진 쪽을 먼저 사본으로 떠 둔다. 덮어쓰기 전에 해야 잃지 않는다.
        if remoteIsNewer {
            try makeConflictCopy(of: id, from: localRoot, entry: local, report: &report)
            try transfer(id: id, from: remoteRoot, to: localRoot, entry: remote, replacing: local, state: &state)
            report.pulled += 1
        } else {
            try makeConflictCopy(of: id, from: remoteRoot, entry: remote, report: &report)
            try transfer(id: id, from: localRoot, to: remoteRoot, entry: local, replacing: remote, state: &state)
            report.pushed += 1
        }
    }

    /// 한쪽 메모 폴더(첨부 포함)를 새 ID로 이쪽 기기의 활성 메모로 복사한다.
    private func makeConflictCopy(of id: MemoID, from root: URL, entry: Entry, report: inout SyncReport) throws {
        let source = memoDirectory(id: id, root: root, inTrash: entry.isInTrash)
        guard var document = try? readDocument(id: id, root: root, inTrash: entry.isInTrash) else { return }

        let newID = MemoID.generate()
        document.meta.conflictOf = id
        document.meta.id = newID

        let destination = memoDirectory(id: newID, root: localRoot, inTrash: false)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(newID.rawValue).tmp", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: source, to: staging)
        try Data(FrontmatterCodec.encode(document).utf8)
            .write(to: staging.appendingPathComponent(Self.memoFileName), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: destination)
        report.conflicts += 1
        report.conflictCopies.append(newID)
    }

    /// 한쪽에서 버린 메모를 다른 쪽에서도 휴지통으로 옮긴다.
    /// 영구 삭제는 하지 않는다 - 되돌릴 수 있어야 한다 (TRS-02).
    /// 단, 반대쪽이 지난번 맞춘 뒤로 고쳐졌다면 그 편집본을 새 ID의 활성 메모로 남긴 뒤에 옮긴다.
    private func propagateTrashState(
        id: MemoID,
        local: Entry,
        remote: Entry,
        mode: SyncMode,
        lastSynced: Date?,
        lastHashes: [String]?,
        state: inout SyncState,
        report: inout SyncReport
    ) throws {
        let trashedSideIsLocal = local.isInTrash
        if trashedSideIsLocal {
            guard mode != .pull else { return }
        } else {
            guard mode != .push else { return }
        }

        let active = trashedSideIsLocal ? remote : local
        let activeRoot = trashedSideIsLocal ? remoteRoot : localRoot
        let trashed = trashedSideIsLocal ? local : remote
        try expect(id: id, root: activeRoot, inTrash: false, hash: active.hash)

        // 휴지통 쪽과 내용이 같으면 고친 것이 아니다.
        if hasChanged(active, lastSynced: lastSynced, lastHashes: lastHashes), active.hash != trashed.hash {
            try makeConflictCopy(of: id, from: activeRoot, entry: active, report: &report)
        }

        if trashedSideIsLocal {
            try transfer(id: id, from: localRoot, to: remoteRoot, entry: local, replacing: remote, state: &state)
            try removeMemo(id: id, root: remoteRoot, inTrash: false)
        } else {
            try transfer(id: id, from: remoteRoot, to: localRoot, entry: remote, replacing: local, state: &state)
            try removeMemo(id: id, root: localRoot, inTrash: false)
        }
        report.deletions += 1
    }

    /// 그룹 목록은 합집합으로 맞춘다. 한쪽에서 만든 그룹이 사라지지 않게 한다.
    private func mergeGroups(mode: SyncMode) throws {
        let localGroups = readGroups(at: localRoot)
        let remoteGroups = readGroups(at: remoteRoot)
        guard localGroups != remoteGroups else { return }

        var merged = localGroups
        for group in remoteGroups where !merged.contains(group) {
            merged.append(group)
        }

        if mode != .pull { try writeGroups(merged, at: remoteRoot) }
        if mode != .push { try writeGroups(merged, at: localRoot) }
    }

    /// 보드 배치는 파일 수정 시각이 최신인 쪽을 원자적으로 복사한다 (설계서 §4, SYNC-06).
    private func syncBoard(mode: SyncMode, state: inout SyncState) throws {
        let local = localRoot.appendingPathComponent(Self.boardFileName)
        let remote = remoteRoot.appendingPathComponent(Self.boardFileName)
        func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        let localDate = modified(local)
        let remoteDate = modified(remote)
        let source: URL
        let destination: URL
        let date: Date
        switch (localDate, remoteDate) {
        case (let left?, let right?) where left == right:
            state.dates[Self.boardFileName] = left
            return
        case (let left?, let right?) where left > right:
            guard mode != .pull else { return }
            (source, destination, date) = (local, remote, left)
        case (let left?, nil):
            guard mode != .pull else { return }
            (source, destination, date) = (local, remote, left)
        case (_, let right?):
            guard mode != .push else { return }
            (source, destination, date) = (remote, local, right)
        case (nil, nil):
            return
        }
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        // 복사로 수정 시각이 바뀌면 다음 동기화에서 역방향 복사가 반복된다.
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
        state.dates[Self.boardFileName] = date
    }

    // MARK: - 파일 다루기

    struct Entry {
        var modified: Date
        var isInTrash: Bool
        /// memo.md 바이트의 SHA-256 (16진수).
        var hash: String
        /// 파일 수정 시각. 바깥에서 고쳐진 파일의 `modified`를 바로잡는 데 쓴다.
        var fileModified: Date?
        /// 다른 앱에서 고쳐 `modified`가 따라오지 못한 파일인가.
        var isExternal = false
    }

    private struct ScanResult {
        var entries: [MemoID: Entry] = [:]
        /// 파일은 있는데 프론트매터를 읽지 못한 메모.
        var unreadable: Set<MemoID> = []
    }

    /// 폴더를 훑어 메모별 수정 시각과 내용 지문을 모은다.
    private func scan(root: URL) -> ScanResult {
        var result = ScanResult()
        for inTrash in [false, true] {
            let folder = root.appendingPathComponent(inTrash ? Self.trashFolder : Self.memosFolder, isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries {
                let id = MemoID(rawValue: entry.lastPathComponent)
                guard id.isValid else { continue }
                let file = entry.appendingPathComponent(Self.memoFileName)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                guard let data = try? Data(contentsOf: file),
                      let text = String(data: data, encoding: .utf8),
                      let document = try? FrontmatterCodec.decode(fileContents: text)
                else {
                    result.unreadable.insert(id)
                    continue
                }
                guard !document.meta.isLocked else { continue }
                result.entries[id] = Entry(
                    modified: document.meta.modified,
                    isInTrash: inTrash,
                    hash: Self.hexDigest(of: data),
                    fileModified: (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                )
            }
        }
        return result
    }

    private static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(of url: URL) -> String? {
        (try? Data(contentsOf: url)).map(hexDigest(of:))
    }

    private func memoFileURL(id: MemoID, root: URL, inTrash: Bool) -> URL {
        memoDirectory(id: id, root: root, inTrash: inTrash).appendingPathComponent(Self.memoFileName)
    }

    private func memoDirectory(id: MemoID, root: URL, inTrash: Bool) -> URL {
        root
            .appendingPathComponent(inTrash ? Self.trashFolder : Self.memosFolder, isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// 메모 폴더를 통째로 옮긴다. 첨부 이미지도 함께 따라간다 (IMG-07).
    private func copyMemo(id: MemoID, from source: URL, to destination: URL, inTrash: Bool) throws {
        let sourceDirectory = memoDirectory(id: id, root: source, inTrash: inTrash)
        guard FileManager.default.fileExists(atPath: sourceDirectory.path) else { return }

        let destinationDirectory = memoDirectory(id: id, root: destination, inTrash: inTrash)
        try FileManager.default.createDirectory(
            at: destinationDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 옮기는 도중 끊겨도 반쪽짜리가 남지 않도록, 임시 폴더에 복사한 뒤 바꿔치기한다.
        let staging = destinationDirectory.deletingLastPathComponent()
            .appendingPathComponent(".\(id.rawValue).tmp", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: sourceDirectory, to: staging)

        if FileManager.default.fileExists(atPath: destinationDirectory.path) {
            _ = try FileManager.default.replaceItemAt(destinationDirectory, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destinationDirectory)
        }
        try? FileManager.default.removeItem(at: staging)
    }

    private func removeMemo(id: MemoID, root: URL, inTrash: Bool) throws {
        let directory = memoDirectory(id: id, root: root, inTrash: inTrash)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func readDocument(id: MemoID, root: URL, inTrash: Bool) throws -> MemoDocument {
        let url = memoDirectory(id: id, root: root, inTrash: inTrash).appendingPathComponent(Self.memoFileName)
        return try FrontmatterCodec.decode(fileContents: String(contentsOf: url, encoding: .utf8))
    }

    private func writeDocument(_ document: MemoDocument, root: URL, inTrash: Bool) throws {
        let directory = memoDirectory(id: document.meta.id, root: root, inTrash: inTrash)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = FrontmatterCodec.encode(document)
        try Data(text.utf8).write(to: directory.appendingPathComponent(Self.memoFileName), options: .atomic)
    }

    private func readGroups(at root: URL) -> [String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(Self.groupsFileName)),
              let groups = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return groups
    }

    private func writeGroups(_ groups: [String], at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(groups).write(to: root.appendingPathComponent(Self.groupsFileName), options: .atomic)
    }

    private func prepareFolders() throws {
        for root in [localRoot, remoteRoot] {
            for folder in [Self.memosFolder, Self.trashFolder] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(folder, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        }
    }

    /// 같은 시각인지 본다.
    ///
    /// 비교하는 두 값은 모두 파일에 적힌 밀리초 단위 시각에서 온다.
    /// 여기서 허용 오차를 넉넉히 잡으면 빠르게 이어진 수정을 "안 바뀐 것"으로 보아
    /// 변경이 조용히 묻힌다. 기록 중 생기는 소수점 오차만 흡수할 만큼만 둔다.
    func isSameMoment(_ left: Date?, _ right: Date?) -> Bool {
        guard let left, let right else { return false }
        return abs(left.timeIntervalSince1970 - right.timeIntervalSince1970) < 0.0005
    }

    // MARK: - 동기화 기록

    /// 동기화 기록.
    ///
    /// 시각은 예전부터 써 온 `sync-state.json`(`{"<메모ID>": "<시각>"}` 평면 사전)에 그대로 적는다.
    /// 내용 지문은 그 옆의 `sync-state.hashes.json`에 따로 적는다. 이렇게 하면 예전 형식 파일이 그대로 읽히고
    /// (지문 파일이 없으면 `modified`로 판단), 예전 버전 앱이 상태 파일을 읽어도 깨지지 않는다.
    struct SyncState {
        /// 메모별로 마지막에 맞춘 `modified` (보드 파일 항목 포함).
        var dates: [String: Date] = [:]
        /// 메모별로 마지막에 맞춘 memo.md 지문. 보낸 쪽과 받은 쪽이 다를 수 있어 목록으로 둔다.
        var hashes: [String: [String]] = [:]

        mutating func record(_ key: String, date: Date, hashes list: [String]) {
            dates[key] = date
            var unique: [String] = []
            for hash in list where !unique.contains(hash) { unique.append(hash) }
            hashes[key] = unique
        }

        mutating func forget(_ key: String) {
            dates.removeValue(forKey: key)
            hashes.removeValue(forKey: key)
        }
    }

    /// 지문 파일의 항목. 어느 시각 기록과 짝인지 함께 적어, 시각만 따로 갱신된 경우를 걸러 낸다.
    struct HashRecord: Codable {
        var date: Date
        var hashes: [String]
    }

    private var hashesURL: URL {
        stateURL.deletingPathExtension().appendingPathExtension("hashes.json")
    }

    // 테스트와 골든이 실제 상태 읽기와 쓰기를 재사용하도록 모듈 내부에 연다.
    func loadState() -> SyncState {
        var state = SyncState()
        if let data = try? Data(contentsOf: stateURL),
           let dates = try? JSONDecoder().decode([String: Date].self, from: data) {
            state.dates = dates
        }
        if let data = try? Data(contentsOf: hashesURL),
           let records = try? JSONDecoder().decode([String: HashRecord].self, from: data) {
            for (key, record) in records where state.dates[key] == record.date {
                state.hashes[key] = record.hashes
            }
        }
        return state
    }

    func saveState(_ state: SyncState) {
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(state.dates).write(to: stateURL, options: .atomic)

        var records: [String: HashRecord] = [:]
        for (key, hashes) in state.hashes {
            guard let date = state.dates[key] else { continue }
            records[key] = HashRecord(date: date, hashes: hashes)
        }
        try? JSONEncoder().encode(records).write(to: hashesURL, options: .atomic)
    }
}
