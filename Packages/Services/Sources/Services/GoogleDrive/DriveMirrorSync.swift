import CryptoKit
import Foundation
import MemoCore

public enum DriveSyncError: Error, LocalizedError {
    /// 올리거나 지우지 못한 파일이 있다. 상태에 적지 않았으므로 다음 동기화에서 다시 한다.
    case incomplete(Int)

    public var errorDescription: String? {
        switch self {
        case .incomplete(let count): return "드라이브에 반영하지 못한 파일이 \(count)개 있습니다. 다음에 다시 시도합니다."
        }
    }
}

/// 로컬 "드라이브 거울 폴더"와 구글 드라이브 사이를 맞춘다.
///
/// 메모끼리의 비교 · 충돌 사본 · 개인정보 정리는 기존 `SyncService`가 그대로 맡는다.
/// 이 엔진은 데이터 폴더와 거울 폴더 사이를 맞추고(원격이 iCloud 폴더가 아니라 거울일 뿐),
/// 이 타입은 거울과 드라이브 사이만 맞춘다.
///
/// 한 번의 동기화: (1) 드라이브 -> 거울 내려받기 (2) `SyncService` 양방향 (3) 거울 -> 드라이브 올리기.
public struct DriveMirrorSync: Sendable {
    public var service: SyncService
    private let mirrorRoot: URL
    private let stateURL: URL
    private let api: any DriveAPI
    private let log: @Sendable (String) -> Void

    private static let rootFolderName = AppStorageName.folder

    public init(
        localRoot: URL,
        mirrorRoot: URL,
        driveStateURL: URL,
        engineStateURL: URL,
        api: any DriveAPI,
        keychain: any MemoKeychain = DeviceMemoKeychain(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.service = SyncService(localRoot: localRoot, remoteRoot: mirrorRoot, stateURL: engineStateURL, keychain: keychain)
        self.mirrorRoot = mirrorRoot
        self.stateURL = driveStateURL
        self.api = api
        self.log = log
    }

    // MARK: - 기본 경로 (데이터 폴더 밖)

    static func supportFolder() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppStorageName.folder, isDirectory: true)
    }

    public static func defaultGoogleFolder() -> URL {
        supportFolder().appendingPathComponent("GoogleDrive", isDirectory: true)
    }

    public static func defaultMirrorRoot() -> URL {
        defaultGoogleFolder().appendingPathComponent(AppStorageName.folder, isDirectory: true)
    }

    public static func defaultDriveStateURL() -> URL {
        defaultGoogleFolder().appendingPathComponent("drive-state.json")
    }

    public static func defaultEngineStateURL() -> URL {
        supportFolder().appendingPathComponent("sync-state-google.json")
    }

    /// 로그아웃할 때 거울 폴더와 드라이브 · 엔진 상태 파일을 지운다. 데이터 폴더는 건드리지 않는다.
    public static func resetLocalState(
        googleFolder: URL = defaultGoogleFolder(),
        engineStateURL: URL = defaultEngineStateURL()
    ) {
        try? FileManager.default.removeItem(at: googleFolder)
        try? FileManager.default.removeItem(at: engineStateURL)
        try? FileManager.default.removeItem(at: engineStateURL.deletingPathExtension().appendingPathExtension("hashes.json"))
    }

    // MARK: - 상태

    struct FileRecord: Codable, Equatable {
        var fileID: String
        /// 마지막으로 맞춘 드라이브 쪽 값(md5).
        var remoteMD5: String
        /// 마지막으로 맞춘 거울 파일의 md5.
        var syncedMD5: String
        /// 개인정보 때문에 드라이브에서 지워야 하는 파일. 첫 동기화 규칙과 상관없이 지운다.
        var purge: Bool?
    }

    struct DriveState: Codable, Equatable {
        var rootID: String?
        var files: [String: FileRecord] = [:]
        /// 상대 경로 -> 폴더 id
        var folders: [String: String] = [:]
        /// 올리기까지 한 번이라도 끝까지 마쳤는가. 그 전(첫 동기화)에는 아무것도 지우지 않는다.
        var completedOnce = false
    }

    // 테스트와 골든이 실제 상태 읽기와 쓰기를 재사용하도록 모듈 내부에 연다.
    func loadState() -> DriveState {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(DriveState.self, from: data) else {
            return DriveState()
        }
        return state
    }

    func saveState(_ state: DriveState) {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    // MARK: - 동기화

    public func sync(mode: SyncMode = .both) async throws -> SyncReport {
        var state = loadState()
        if mode != .push {
            try await download(into: &state)
        }
        let report = try service.sync(mode: mode)
        if mode != .pull {
            try await upload(state: &state)
        }
        return report
    }

    /// 파기 · 로컬 전용 정리를 거울까지 반영하고, 거울에서 사라진 파일을 드라이브에서도 영구 삭제한다.
    /// 드라이브에 닿지 못해도 로컬 정리는 끝난 것이다. 남은 삭제는 다음 동기화가 한다.
    public func enforcePrivacy() async throws -> SyncReport {
        let report = try service.enforcePrivacy()
        var state = loadState()
        if state.completedOnce || !state.files.isEmpty {
            try? await upload(state: &state)
        }
        return report
    }

    // MARK: - (1) 드라이브 -> 거울

    private struct RemoteTree {
        var rootID: String?
        var files: [String: DriveFile] = [:]
        var folders: [String: String] = [:]
    }

    private func isIgnoredName(_ name: String) -> Bool {
        name.isEmpty || name.hasPrefix(".") || name.hasSuffix(".tmp") || name.contains("/")
    }

    private func fetchTree(_ state: DriveState) async throws -> RemoteTree {
        let all = try await api.list()
        let folderIDs = Set(all.filter(\.isFolder).map(\.id))
        var tree = RemoteTree()

        if let known = state.rootID, folderIDs.contains(known) {
            tree.rootID = known
        } else {
            let candidates = all.filter { $0.isFolder && $0.name == Self.rootFolderName && !$0.parents.contains(where: folderIDs.contains) }
                .sorted { ($0.modifiedTime ?? .distantPast) > ($1.modifiedTime ?? .distantPast) }
            if candidates.count > 1 { log("드라이브에 같은 이름의 \(Self.rootFolderName) 폴더가 \(candidates.count)개 있어 가장 최근 것만 씁니다") }
            tree.rootID = candidates.first?.id
        }
        guard let rootID = tree.rootID else { return tree }

        // 같은 부모 안에서 이름이 겹치면 가장 최근 것만 쓴다.
        var children: [String: [DriveFile]] = [:]
        for file in all { for parent in file.parents { children[parent, default: []].append(file) } }

        var queue: [(id: String, path: String)] = [(rootID, "")]
        while !queue.isEmpty {
            let (parentID, parentPath) = queue.removeFirst()
            var byName: [String: DriveFile] = [:]
            for child in children[parentID] ?? [] where !isIgnoredName(child.name) {
                if let existing = byName[child.name] {
                    log("드라이브 같은 폴더에 \(child.name) 이름이 겹쳐 가장 최근 것만 씁니다")
                    if (child.modifiedTime ?? .distantPast) > (existing.modifiedTime ?? .distantPast) { byName[child.name] = child }
                } else {
                    byName[child.name] = child
                }
            }
            for (name, child) in byName {
                let path = parentPath.isEmpty ? name : parentPath + "/" + name
                if child.isFolder {
                    tree.folders[path] = child.id
                    queue.append((child.id, path))
                } else {
                    tree.files[path] = child
                }
            }
        }
        return tree
    }

    private func download(into state: inout DriveState) async throws {
        // 목록이나 내려받기 중 하나라도 실패하면 여기서 던진다. 거울과 상태는 아직 아무것도 바뀌지 않았다.
        let tree = try await fetchTree(state)
        let blocked = blockedIDs()
        var updated = state
        var plan: [(path: String, file: DriveFile)] = []

        for (path, file) in tree.files.sorted(by: { $0.key < $1.key }) {
            let target = mirrorRoot.appendingPathComponent(path)
            if Self.isBlocked(path: path, blocked: blocked) {
                // 암호 메모와 파기한 메모는 받지 않는다. 드라이브에 남아 있다면 올리기 단계에서 영구 삭제한다.
                if updated.files[path] == nil || updated.files[path]?.purge != true {
                    updated.files[path] = FileRecord(fileID: file.id, remoteMD5: file.changeToken, syncedMD5: "", purge: true)
                }
                continue
            }
            if var record = updated.files[path] {
                if record.remoteMD5 == file.changeToken {
                    if record.fileID != file.id { record.fileID = file.id; updated.files[path] = record }
                    continue
                }
            } else if let local = Self.md5(of: target), local == file.md5 {
                updated.files[path] = FileRecord(fileID: file.id, remoteMD5: file.changeToken, syncedMD5: local)
                continue
            }
            // 원격만 바뀌었거나 양쪽 다 바뀐 경우 모두 원격을 거울에 받는다.
            // 데이터 폴더의 로컬 내용은 남아 있어 엔진이 충돌 사본으로 처리한다.
            plan.append((path, file))
        }

        let staging = mirrorRoot.deletingLastPathComponent().appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var staged: [(path: String, file: DriveFile, url: URL)] = []
        if !plan.isEmpty { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
        for (index, item) in plan.enumerated() {
            let data = try await api.download(id: item.file.id)
            let url = staging.appendingPathComponent(String(index))
            try data.write(to: url)
            staged.append((item.path, item.file, url))
        }

        // 여기까지 왔으면 모두 받았다. 이제 거울에 반영한다.
        try FileManager.default.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
        for item in staged {
            let target = mirrorRoot.appendingPathComponent(item.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: item.url)
            } else {
                try FileManager.default.moveItem(at: item.url, to: target)
            }
            updated.files[item.path] = FileRecord(
                fileID: item.file.id,
                remoteMD5: item.file.changeToken,
                syncedMD5: Self.md5(of: target) ?? ""
            )
        }

        // 원격에서 사라진 것(상태에는 있음)은 거울에서도 지운다. 첫 동기화 전에는 지우지 않는다.
        if updated.completedOnce {
            for (path, record) in updated.files where tree.files[path] == nil && record.purge != true {
                let target = mirrorRoot.appendingPathComponent(path)
                try? FileManager.default.removeItem(at: target)
                removeEmptyParents(of: target)
                updated.files[path] = nil
            }
        } else {
            // 첫 동기화: 상태에 있던 항목이 없으니 지울 것이 없다. 모르는 항목은 그대로 둔다.
        }
        // 드라이브에서 사라진 purge 항목은 이미 지워진 것이다.
        for (path, record) in updated.files where record.purge == true && tree.files[path] == nil { updated.files[path] = nil }

        updated.rootID = tree.rootID ?? updated.rootID
        updated.folders = tree.folders
        state = updated
        saveState(state)
    }

    private func removeEmptyParents(of url: URL) {
        var folder = url.deletingLastPathComponent()
        let root = mirrorRoot.standardizedFileURL.path
        while folder.standardizedFileURL.path.count > root.count, folder.standardizedFileURL.path.hasPrefix(root) {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path), items.isEmpty else { return }
            try? FileManager.default.removeItem(at: folder)
            folder = folder.deletingLastPathComponent()
        }
    }

    // MARK: - (3) 거울 -> 드라이브

    private func upload(state: inout DriveState) async throws {
        let blocked = blockedIDs()
        let mirrorFiles = walkMirror().filter { !Self.isBlocked(path: $0.key, blocked: blocked) }
        var failed = 0

        func folderID(for path: String, state: inout DriveState) async throws -> String? {
            // 드라이브 최상위 MDemo 폴더 아래 경로의 폴더를 차례로 확인하고 없으면 만든다.
            if state.rootID == nil {
                let root = try await api.createFolder(name: Self.rootFolderName, parentID: nil)
                state.rootID = root.id
            }
            var current = state.rootID
            var prefix = ""
            for component in path.split(separator: "/").map(String.init) {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                if let known = state.folders[prefix] {
                    current = known
                } else {
                    let folder = try await api.createFolder(name: component, parentID: current)
                    state.folders[prefix] = folder.id
                    current = folder.id
                }
            }
            return current
        }

        for (path, hash) in mirrorFiles.sorted(by: { $0.key < $1.key }) {
            if let record = state.files[path], record.syncedMD5 == hash { continue }
            do {
                let data = try Data(contentsOf: mirrorRoot.appendingPathComponent(path))
                let name = (path as NSString).lastPathComponent
                let parent = try await folderID(for: (path as NSString).deletingLastPathComponent, state: &state)
                let result: DriveFile
                if let record = state.files[path], record.purge != true {
                    do { result = try await api.update(id: record.fileID, data: data) }
                    catch DriveError.notFound { result = try await api.upload(name: name, parentID: parent, data: data) }
                } else {
                    result = try await api.upload(name: name, parentID: parent, data: data)
                }
                state.files[path] = FileRecord(fileID: result.id, remoteMD5: result.changeToken, syncedMD5: hash)
            } catch {
                failed += 1
                log("올리지 못함: \(path) (\(error.localizedDescription))")
            }
        }

        // 거울에서 사라진 파일은 드라이브에서 영구 삭제한다.
        var purged = 0
        for (path, record) in state.files.sorted(by: { $0.key < $1.key }) where mirrorFiles[path] == nil {
            guard state.completedOnce || record.purge == true else { continue }
            do {
                do { try await api.delete(id: record.fileID) } catch DriveError.notFound {}
                state.files[path] = nil
                if record.purge == true { purged += 1 }
            } catch {
                failed += 1
                log("지우지 못함: \(path) (\(error.localizedDescription))")
            }
        }

        // 안에 파일이 하나도 없게 된 드라이브 폴더도 지운다. 깊은 폴더부터.
        if state.completedOnce || purged > 0 {
            for (path, id) in state.folders.sorted(by: { $0.key.count > $1.key.count }) {
                let prefix = path + "/"
                let hasFiles = state.files.keys.contains { $0.hasPrefix(prefix) }
                let hasSubfolders = state.folders.keys.contains { $0.hasPrefix(prefix) }
                guard !hasFiles, !hasSubfolders else { continue }
                do {
                    do { try await api.delete(id: id) } catch DriveError.notFound {}
                    state.folders[path] = nil
                } catch {
                    log("폴더를 지우지 못함: \(path) (\(error.localizedDescription))")
                }
            }
        }

        if failed == 0 { state.completedOnce = true }
        saveState(state)
        if failed > 0 { throw DriveSyncError.incomplete(failed) }
    }

    // MARK: - 거울 폴더 훑기

    /// 상대 경로 -> md5. 숨김 파일과 `.tmp`는 뺀다.
    private func walkMirror() -> [String: String] {
        let base = mirrorRoot.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [:] }
        var result: [String: String] = [:]
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        while let url = enumerator.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.split(separator: "/").contains(where: { $0.hasSuffix(".tmp") }) else { continue }
            if let hash = Self.md5(of: url) { result[relative] = hash }
        }
        return result
    }

    /// 거울의 장부에 적힌 파기 · 로컬 전용(암호 메모) 메모 ID.
    private func blockedIDs() -> Set<String> {
        var ids = Set<String>()
        for name in ["destroyed", "local-only"] {
            ids.formUnion((try? MemoPrivacyLedger.read(name, root: mirrorRoot)) ?? [])
            ids.formUnion((try? MemoPrivacyLedger.read(name, root: service.localRoot)) ?? [])
        }
        return ids
    }

    /// `memos/<id>/...` 또는 `trash/<id>/...` 가 막힌 ID의 것인가.
    static func isBlocked(path: String, blocked: Set<String>) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "memos" || parts[0] == "trash" else { return false }
        return blocked.contains(String(parts[1]))
    }

    static func md5(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return md5(of: data)
    }

    public static func md5(of data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
