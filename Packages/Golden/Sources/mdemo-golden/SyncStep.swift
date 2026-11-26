import Foundation
import MemoCore
@testable import Services

// 기존 ServicesTests와 같은 FakeDrive 소스를 사용한다. 실제 키체인과 통신은 없다.
func runSyncStep(file: URL, root: URL) async throws {
    let fm = FileManager.default
    let op = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    let dir = root.appendingPathComponent(op["device"] as! String)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let keychain = EmptyKeychain()
    let backup = BackupService(dataRoot: dir.appendingPathComponent("Data"), keychain: keychain)
    let action = op["action"] as? String ?? "sync"
    if action == "boundaries" {
        let service = SyncService(localRoot: dir, remoteRoot: dir, stateURL: dir.appendingPathComponent("state.json"), keychain: keychain)
        let last = Date(timeIntervalSinceReferenceDate: 123)
        let values = [-0.0006, -0.0005, -0.0004, 0, 0.0004, 0.0005, 0.0006].map { delta in
            let date = last.addingTimeInterval(delta)
            let entry = SyncService.Entry(modified: date, isInTrash: false, hash: "changed", fileModified: nil)
            return [service.isSameMoment(date, last), service.isExternalEdit(entry, lastSynced: last, lastHashes: ["before"]), service.isExternalEdit(entry, lastSynced: last, lastHashes: nil)]
        }
        try JSONSerialization.data(withJSONObject: values).write(to: root.appendingPathComponent("result.json"))
        return
    }
    if action == "export" || action == "import" {
        let archive = root.appendingPathComponent(op["archive"] as! String)
        let count = try action == "export" ? backup.exportBackup(to: archive) : backup.importBackup(from: archive, replaceExisting: op["replace"] as? Bool ?? false)
        try Data(String(count).utf8).write(to: root.appendingPathComponent("result.json"))
        return
    }
    if action == "state" {
        let service = SyncService(localRoot: dir, remoteRoot: dir, stateURL: dir.appendingPathComponent("sync-state-google.json"), keychain: keychain)
        service.saveState(service.loadState())
        return
    }
    let drive = FakeDrive()
    try drive.loadFixture(from: root.appendingPathComponent("drive.json"))
    drive.fixedTime = Date(timeIntervalSinceReferenceDate: 123)
    drive.failures = Set(op["failures"] as? [String] ?? [])
    var sync = DriveMirrorSync(localRoot: dir.appendingPathComponent("Data"), mirrorRoot: dir.appendingPathComponent("Mirror"), driveStateURL: dir.appendingPathComponent("drive-state.json"), engineStateURL: dir.appendingPathComponent("sync-state-google.json"), api: drive, keychain: keychain)
    let queue = SyncIDs(op["ids"] as? [String] ?? [])
    sync.service.generateID = { queue.next() }
    let mode: SyncMode = switch op["mode"] as? String { case "push": .push; case "pull": .pull; default: .both }
    let expected = op["expectError"] as? Bool ?? false
    var result: [String: Any]
    var failed = false
    do {
        let report = try await sync.sync(mode: mode)
        result = ["pushed": report.pushed, "pulled": report.pulled, "conflicts": report.conflicts, "deletions": report.deletions, "unreadable": report.unreadable, "lockedLocal": report.lockedLocal, "removedLocalOnly": report.removedLocalOnly]
    } catch {
        if !expected { throw error }
        failed = true
        result = ["error": true]
    }
    if expected != failed { throw ScenarioError("동기화 오류 여부 불일치") }
    try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: root.appendingPathComponent("result.json"))
    try drive.saveFixture(to: root.appendingPathComponent("drive.json"))
}
private final class SyncIDs: @unchecked Sendable {
    private var values: [String]
    init(_ values: [String]) { self.values = values }
    func next() -> MemoID { precondition(!values.isEmpty, "준비된 충돌 ID가 없음"); return MemoID(rawValue: values.removeFirst()) }
}
