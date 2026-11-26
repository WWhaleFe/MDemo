import CoreBridge
import Foundation
import MemoCore

extension SyncMode {
    var core: CoreSyncMode { switch self { case .both: .both; case .push: .push; case .pull: .pull } }
}
extension CoreSyncReport {
    var native: SyncReport {
        var r = SyncReport()
        r.pushed = Int(pushed); r.pulled = Int(pulled); r.conflicts = Int(conflicts)
        r.deletions = Int(deletions); r.unreadable = Int(unreadable)
        r.lockedLocal = Int(lockedLocal); r.removedLocalOnly = Int(removedLocalOnly)
        r.conflictCopies = conflictCopies.map { MemoID(rawValue: $0) }
        return r
    }
}
private final class SyncHooks: CoreSyncHooks, @unchecked Sendable {
    let service: SyncService
    init(_ service: SyncService) { self.service = service }
    func generateId() -> String { service.generateID().rawValue }
    func afterScan() { service.afterScan?() }
}
extension SyncService {
    func rustService() -> CoreSyncService {
        CoreSyncService(local: localRoot.path, remote: remoteRoot.path, state: stateURL.path,
                        keys: CoreStorage.bridgeKeys(keychain), hooks: SyncHooks(self))
    }
}
func rustCall<T>(_ action: () throws -> T) throws -> T {
    do { return try action() }
    catch CoreSyncError.Drive(let error) {
        switch error {
        case .NotFound: throw DriveError.notFound
        case .Http(let status, let message): throw DriveError.http(Int(status), message)
        case .InvalidResponse: throw DriveError.invalidResponse
        case .Incomplete(let count): throw DriveSyncError.incomplete(Int(count))
        }
    }
    catch CoreSyncError.Io(let message) {
        throw NSError(domain: "MDemoSync", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// 대기하는 스레드는 전용 큐에만 있다. Task는 별도로 실행되어 MainActor API도 호출할 수 있다.
private final class DriveResult<T: Sendable>: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    var value: Result<T, Error>?
}
final class RustDriveAdapter: CoreDriveApi, @unchecked Sendable {
    private let api: any DriveAPI
    init(_ api: any DriveAPI) { self.api = api }
    private func wait<T: Sendable>(_ action: @escaping @Sendable () async throws -> T) throws -> T {
        precondition(!Thread.isMainThread, "드라이브 콜백은 백그라운드에서만 대기한다")
        let result = DriveResult<T>()
        Task.detached {
            do { result.value = .success(try await action()) }
            catch let error as DriveError {
                switch error {
                case .notFound: result.value = .failure(CoreDriveError.NotFound)
                case .http(let status, let message): result.value = .failure(CoreDriveError.Http(status: Int32(status), message: message))
                case .invalidResponse: result.value = .failure(CoreDriveError.InvalidResponse)
                }
            } catch { result.value = .failure(CoreDriveError.Http(status: -1, message: error.localizedDescription)) }
            result.ready.signal()
        }
        result.ready.wait()
        return try result.value!.get()
    }
    func list() throws -> [CoreDriveFile] { try wait { try await self.api.list() }.map(\.core) }
    func download(id: String) throws -> Data { try wait { try await self.api.download(id: id) } }
    func upload(name: String, parentId: String?, data: Data) throws -> CoreDriveFile {
        try wait { try await self.api.upload(name: name, parentID: parentId, data: data) }.core
    }
    func update(id: String, data: Data) throws -> CoreDriveFile { try wait { try await self.api.update(id: id, data: data) }.core }
    func createFolder(name: String, parentId: String?) throws -> CoreDriveFile {
        try wait { try await self.api.createFolder(name: name, parentID: parentId) }.core
    }
    func delete(id: String) throws { try wait { try await self.api.delete(id: id) } }
}
private extension DriveFile {
    var core: CoreDriveFile {
        CoreDriveFile(id: id, name: name, mimeType: mimeType, md5: md5, parents: parents,
                      modifiedTime: modifiedTime?.timeIntervalSinceReferenceDate)
    }
}

func rustDriveSync(service: SyncService, state: URL, api: any DriveAPI, mode: SyncMode, privacy: Bool) async throws -> SyncReport {
    try await withCheckedThrowingContinuation { continuation in
        // 협력 스레드 풀에서 세마포어를 기다리지 않도록 호출마다 전용 큐를 둔다.
        DispatchQueue(label: "MDemo.rust-drive", qos: .utility).async {
            continuation.resume(with: Result {
                try rustCall {
                    try coreDriveSync(service: service.rustService(), state: state.path,
                                      api: RustDriveAdapter(api), mode: mode.core, privacy: privacy)
                }.native
            })
        }
    }
}
