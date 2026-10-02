import Foundation
import MemoCore

/// iCloud Drive 폴더를 사이에 두고 기기끼리 메모를 주고받는다 (SYNC-01~06).
///
/// **왜 iCloud Drive의 일반 폴더인가**: 유비쿼티 컨테이너나 CloudKit은 유료 개발자 계정이
/// 있어야 쓸 수 있다. iCloud Drive 폴더는 일반 파일 경로라 그런 제약이 없고,
/// 파일을 기기 사이로 나르는 일은 macOS가 알아서 한다.
/// 이 서비스가 하는 일은 "내 폴더 ↔ iCloud 폴더" 사이의 비교와 복사뿐이다.
///
/// **작업 데이터는 늘 로컬에 둔다**: iCloud 폴더를 직접 작업 폴더로 쓰면
/// 아직 내려받지 않은 파일이나 동기화 지연이 편집 경로에 끼어든다.
public struct SyncReport: Sendable, Equatable {
    /// 내 것을 iCloud로 올린 메모 수.
    public var pushed = 0
    /// iCloud 것을 내려받은 메모 수.
    public var pulled = 0
    /// 양쪽이 모두 바뀌어 사본을 남긴 메모 수 (SYNC-06).
    public var conflicts = 0
    /// 삭제가 전파된 메모 수.
    public var deletions = 0

    public var isEmpty: Bool {
        pushed == 0 && pulled == 0 && conflicts == 0 && deletions == 0
    }

    public var summary: String {
        guard !isEmpty else { return "변경 없음" }
        var parts: [String] = []
        if pushed > 0 { parts.append("올림 \(pushed)") }
        if pulled > 0 { parts.append("내려받음 \(pulled)") }
        if deletions > 0 { parts.append("삭제 반영 \(deletions)") }
        if conflicts > 0 { parts.append("충돌 사본 \(conflicts)") }
        return parts.joined(separator: " · ")
    }
}

public enum SyncMode: Sendable {
    /// 양방향. 자동 동기화가 쓴다.
    case both
    /// 내 변경만 올린다 ("지금 iCloud에 저장", SYNC-02).
    case push
    /// iCloud 변경만 내려받는다 ("iCloud에서 불러오기", SYNC-03).
    case pull
}

public enum SyncError: Error, LocalizedError {
    case iCloudUnavailable

    public var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud Drive를 찾을 수 없습니다. 시스템 설정에서 iCloud Drive를 켜 주세요."
        }
    }
}

public struct SyncService: Sendable {
    public let localRoot: URL
    public let remoteRoot: URL
    /// 마지막으로 맞춰 둔 시각을 메모별로 적어 둔다. 기기마다 따로 갖는다.
    private let stateURL: URL

    private static let memosFolder = "memos"
    private static let trashFolder = "trash"
    private static let memoFileName = "memo.md"
    private static let groupsFileName = "groups.json"

    public init(localRoot: URL, remoteRoot: URL, stateURL: URL) {
        self.localRoot = localRoot
        self.remoteRoot = remoteRoot
        self.stateURL = stateURL
    }

    /// iCloud Drive 최상위 폴더. 꺼져 있으면 nil.
    public static func iCloudDriveRoot() -> URL? {
        let iCloudDrive = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: iCloudDrive.path) ? iCloudDrive : nil
    }

    /// iCloud Drive 안의 앱 폴더. iCloud Drive가 꺼져 있으면 nil.
    public static func defaultRemoteRoot() -> URL? {
        iCloudDriveRoot()?.appendingPathComponent(AppStorageName.folder, isDirectory: true)
    }

    public static func defaultStateURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(AppStorageName.folder)/sync-state.json")
    }

    public static var isICloudAvailable: Bool { defaultRemoteRoot() != nil }

    // MARK: - 동기화

    public func sync(mode: SyncMode = .both) throws -> SyncReport {
        try prepareFolders()

        var state = loadState()
        var report = SyncReport()

        let local = scan(root: localRoot)
        let remote = scan(root: remoteRoot)

        for id in Set(local.keys).union(remote.keys) {
            let localEntry = local[id]
            let remoteEntry = remote[id]
            let lastSynced = state[id.rawValue]

            try reconcile(
                id: id,
                local: localEntry,
                remote: remoteEntry,
                lastSynced: lastSynced,
                mode: mode,
                state: &state,
                report: &report
            )
        }

        try mergeGroups(mode: mode)
        saveState(state)
        return report
    }

    /// 한 메모에 대해 무엇을 할지 정하고 실행한다.
    ///
    /// 판단 기준은 "지난번 맞췄을 때와 달라졌는가"다.
    /// 양쪽 다 달라졌으면 최신본을 남기고 진 쪽은 사본으로 보존한다 — 어느 쪽도 버리지 않는다.
    private func reconcile(
        id: MemoID,
        local: Entry?,
        remote: Entry?,
        lastSynced: Date?,
        mode: SyncMode,
        state: inout [String: Date],
        report: inout SyncReport
    ) throws {
        switch (local, remote) {
        case (nil, nil):
            state.removeValue(forKey: id.rawValue)

        case (let localEntry?, nil):
            if lastSynced == nil {
                // 이 기기에서 새로 만든 메모
                guard mode != .pull else { return }
                try copyMemo(id: id, from: localRoot, to: remoteRoot, inTrash: localEntry.isInTrash)
                state[id.rawValue] = localEntry.modified
                report.pushed += 1
            } else {
                // 저쪽에서 아예 사라졌다. 우리는 지우지 않고 다시 올린다 —
                // 파일이 사라지는 경우는 원인이 다양해서, 되살리는 쪽이 안전하다.
                guard mode != .pull else { return }
                try copyMemo(id: id, from: localRoot, to: remoteRoot, inTrash: localEntry.isInTrash)
                state[id.rawValue] = localEntry.modified
                report.pushed += 1
            }

        case (nil, let remoteEntry?):
            guard mode != .push else { return }
            try copyMemo(id: id, from: remoteRoot, to: localRoot, inTrash: remoteEntry.isInTrash)
            state[id.rawValue] = remoteEntry.modified
            report.pulled += 1

        case (let localEntry?, let remoteEntry?):
            // 한쪽이 휴지통에 있으면 삭제로 본다. 삭제는 어느 쪽이든 따라간다 (TRS-01).
            if localEntry.isInTrash != remoteEntry.isInTrash {
                try propagateTrashState(
                    id: id,
                    local: localEntry,
                    remote: remoteEntry,
                    mode: mode,
                    state: &state,
                    report: &report
                )
                return
            }

            let localChanged = !isSameMoment(localEntry.modified, lastSynced)
            let remoteChanged = !isSameMoment(remoteEntry.modified, lastSynced)

            switch (localChanged, remoteChanged) {
            case (false, false):
                break

            case (true, false):
                guard mode != .pull else { return }
                try copyMemo(id: id, from: localRoot, to: remoteRoot, inTrash: localEntry.isInTrash)
                state[id.rawValue] = localEntry.modified
                report.pushed += 1

            case (false, true):
                guard mode != .push else { return }
                try copyMemo(id: id, from: remoteRoot, to: localRoot, inTrash: remoteEntry.isInTrash)
                state[id.rawValue] = remoteEntry.modified
                report.pulled += 1

            case (true, true):
                guard !isSameMoment(localEntry.modified, remoteEntry.modified) else {
                    state[id.rawValue] = localEntry.modified
                    return
                }
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

    /// 양쪽이 모두 바뀐 경우 (SYNC-06).
    ///
    /// 최신본을 정본으로 삼고, 진 쪽은 새 ID를 붙인 사본으로 남긴다.
    /// 리스트 창이 `conflictOf` 표시를 보고 사용자에게 알려 준다.
    private func resolveConflict(
        id: MemoID,
        local: Entry,
        remote: Entry,
        mode: SyncMode,
        state: inout [String: Date],
        report: inout SyncReport
    ) throws {
        let remoteIsNewer = remote.modified > local.modified

        // 진 쪽을 먼저 사본으로 떠 둔다. 덮어쓰기 전에 해야 잃지 않는다.
        let loserRoot = remoteIsNewer ? localRoot : remoteRoot
        if var loser = try? readDocument(id: id, root: loserRoot, inTrash: local.isInTrash) {
            loser.meta.conflictOf = id
            loser.meta.id = .generate()
            try writeDocument(loser, root: localRoot, inTrash: false)
            report.conflicts += 1
        }

        if remoteIsNewer {
            guard mode != .push else { return }
            try copyMemo(id: id, from: remoteRoot, to: localRoot, inTrash: remote.isInTrash)
            state[id.rawValue] = remote.modified
            report.pulled += 1
        } else {
            guard mode != .pull else { return }
            try copyMemo(id: id, from: localRoot, to: remoteRoot, inTrash: local.isInTrash)
            state[id.rawValue] = local.modified
            report.pushed += 1
        }
    }

    /// 한쪽에서 버린 메모를 다른 쪽에서도 휴지통으로 옮긴다.
    /// 영구 삭제는 하지 않는다 — 되돌릴 수 있어야 한다 (TRS-02).
    private func propagateTrashState(
        id: MemoID,
        local: Entry,
        remote: Entry,
        mode: SyncMode,
        state: inout [String: Date],
        report: inout SyncReport
    ) throws {
        if local.isInTrash {
            guard mode != .pull else { return }
            try copyMemo(id: id, from: localRoot, to: remoteRoot, inTrash: true)
            try removeMemo(id: id, root: remoteRoot, inTrash: false)
            state[id.rawValue] = local.modified
        } else {
            guard mode != .push else { return }
            try copyMemo(id: id, from: remoteRoot, to: localRoot, inTrash: true)
            try removeMemo(id: id, root: localRoot, inTrash: false)
            state[id.rawValue] = remote.modified
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

    // MARK: - 파일 다루기

    private struct Entry {
        var modified: Date
        var isInTrash: Bool
    }

    /// 폴더를 훑어 메모별 수정 시각을 모은다. 본문은 읽지 않는다.
    private func scan(root: URL) -> [MemoID: Entry] {
        var result: [MemoID: Entry] = [:]
        for inTrash in [false, true] {
            let folder = root.appendingPathComponent(inTrash ? Self.trashFolder : Self.memosFolder, isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries {
                let id = MemoID(rawValue: entry.lastPathComponent)
                guard id.isValid else { continue }
                guard let modified = readModified(at: entry.appendingPathComponent(Self.memoFileName)) else { continue }
                result[id] = Entry(modified: modified, isInTrash: inTrash)
            }
        }
        return result
    }

    /// 프론트매터만 읽어 수정 시각을 얻는다.
    private func readModified(at url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard let document = try? FrontmatterCodec.decode(fileContents: text + "\n---\n") else {
            // 앞부분만으로 파싱이 안 되면 통째로 읽어 본다 (프론트매터가 아주 긴 예외적 경우).
            guard let full = try? String(contentsOf: url, encoding: .utf8),
                  let document = try? FrontmatterCodec.decode(fileContents: full)
            else { return nil }
            return document.meta.modified
        }
        return document.meta.modified
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
    private func isSameMoment(_ left: Date?, _ right: Date?) -> Bool {
        guard let left, let right else { return false }
        return abs(left.timeIntervalSince1970 - right.timeIntervalSince1970) < 0.0005
    }

    // MARK: - 동기화 기록

    private func loadState() -> [String: Date] {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return state
    }

    private func saveState(_ state: [String: Date]) {
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
}
