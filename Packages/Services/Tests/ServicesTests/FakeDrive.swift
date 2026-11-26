import Foundation
@testable import Services

/// 드라이브를 흉내 내는 메모리 구현. 호출 기록을 남긴다.
final class FakeDrive: DriveAPI, @unchecked Sendable {
    private let mutex = NSLock()
    private var counter = 0
    private(set) var files: [String: DriveFile] = [:]
    private(set) var contents: [String: Data] = [:]
    private(set) var uploadedPaths: [String] = []
    private(set) var deletedPaths: [String] = []
    private(set) var calls: [String] = []
    var failList = false
    var failDownload = false
    var failures: Set<String> = []
    var fixedTime: Date?

    private func nextID() -> String { counter += 1; return "id\(counter)" }

    private func store(_ file: DriveFile, data: Data?) -> DriveFile {
        var file = file
        if let data { file.md5 = DriveMirrorSync.md5(of: data); contents[file.id] = data }
        file.modifiedTime = fixedTime ?? Date()
        files[file.id] = file
        return file
    }

    /// 드라이브 안의 경로(MDemo 기준)로 파일 id를 찾는다.
    private func path(of file: DriveFile) -> String {
        var parts = [file.name]
        var current = file
        while let parent = current.parents.first, let next = files[parent] {
            if next.parents.isEmpty && next.name == "MDemo" { break }
            parts.insert(next.name, at: 0)
            current = next
        }
        return parts.joined(separator: "/")
    }

    func paths() -> [String] { mutex.lock(); defer { mutex.unlock() }; return files.values.filter { !$0.isFolder }.map(path(of:)).sorted() }
    func data(at path: String) -> Data? {
        mutex.lock(); defer { mutex.unlock() }
        guard let file = files.values.first(where: { !$0.isFolder && self.path(of: $0) == path }) else { return nil }
        return contents[file.id]
    }

    /// 다른 기기가 드라이브에 직접 파일을 둔 것처럼 만든다.
    func put(path: String, data: Data) {
        mutex.lock(); defer { mutex.unlock() }
        var parent: String?
        if let root = files.values.first(where: { $0.isFolder && $0.name == "MDemo" && $0.parents.isEmpty }) { parent = root.id }
        else { parent = store(DriveFile(id: nextID(), name: "MDemo", mimeType: DriveFile.folderMimeType), data: nil).id }
        let components = path.split(separator: "/").map(String.init)
        for name in components.dropLast() {
            if let found = files.values.first(where: { $0.isFolder && $0.name == name && $0.parents == [parent!] }) { parent = found.id }
            else { parent = store(DriveFile(id: nextID(), name: name, mimeType: DriveFile.folderMimeType, parents: [parent!]), data: nil).id }
        }
        let name = components.last!
        if let existing = files.values.first(where: { !$0.isFolder && $0.name == name && $0.parents == [parent!] }) {
            _ = store(existing, data: data)
        } else {
            _ = store(DriveFile(id: nextID(), name: name, parents: [parent!]), data: data)
        }
    }

    func removeRemotely(path: String) {
        mutex.lock(); defer { mutex.unlock() }
        if let file = files.values.first(where: { !$0.isFolder && self.path(of: $0) == path }) { files[file.id] = nil; contents[file.id] = nil }
    }

    func list() async throws -> [DriveFile] {
        try mutex.withLock {
            calls.append("list")
            if failList || failures.contains("list") { throw DriveError.http(500, "목록 실패 주입") }
            return Array(files.values)
        }
    }
    func download(id: String) async throws -> Data {
        try mutex.withLock {
            calls.append("download")
            let ordinal = calls.reversed().prefix(while: { $0 != "list" }).filter { $0 == "download" }.count
            if failDownload || failures.contains("download") || failures.contains("download:\(ordinal)") { throw DriveError.http(500, "내려받기 실패 주입") }
            guard let data = contents[id] else { throw DriveError.notFound }
            return data
        }
    }
    func upload(name: String, parentID: String?, data: Data) async throws -> DriveFile {
        try mutex.withLock {
            calls.append("upload")
            if failures.contains("upload") { throw DriveError.http(500, "실패 주입") }
            let file = store(DriveFile(id: nextID(), name: name, parents: parentID.map { [$0] } ?? []), data: data)
            uploadedPaths.append(path(of: file))
            return file
        }
    }
    func update(id: String, data: Data) async throws -> DriveFile {
        try mutex.withLock {
            calls.append("update")
            if failures.contains("update") { throw DriveError.http(500, "실패 주입") }
            guard let file = files[id] else { throw DriveError.notFound }
            uploadedPaths.append(path(of: file))
            return store(file, data: data)
        }
    }
    func createFolder(name: String, parentID: String?) async throws -> DriveFile {
        try mutex.withLock {
            calls.append("createFolder")
            if failures.contains("createFolder") { throw DriveError.http(500, "실패 주입") }
            return store(DriveFile(id: nextID(), name: name, mimeType: DriveFile.folderMimeType, parents: parentID.map { [$0] } ?? []), data: nil)
        }
    }
    func delete(id: String) async throws {
        try mutex.withLock {
            calls.append("delete")
            if failures.contains("delete") { throw DriveError.http(500, "실패 주입") }
            guard let file = files[id] else { throw DriveError.notFound }
            deletedPaths.append(path(of: file))
            files[id] = nil
            contents[id] = nil
            // 폴더를 지우면 안의 것도 함께 사라진다(영구 삭제).
            for child in files.values where child.parents.contains(id) { files[child.id] = nil; contents[child.id] = nil }
        }
    }
    func saveFixture(to url: URL) throws {
        var records: [String: Any] = [:]
        for (id, f) in files {
            records[id] = ["id": f.id, "name": f.name, "mimeType": f.mimeType,
                           "md5": f.md5 as Any? ?? NSNull(), "parents": f.parents,
                           "modifiedTime": f.modifiedTime.map { $0.timeIntervalSinceReferenceDate } as Any? ?? NSNull()]
        }
        let value: [String: Any] = ["counter": counter, "files": records,
            "contents": contents.mapValues { Array($0) }, "calls": calls,
            "uploaded_paths": uploadedPaths, "deleted_paths": deletedPaths, "failures": Array(failures).sorted()]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }
    func loadFixture(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        counter = value["counter"] as! Int
        files = [:]
        for (id, item) in value["files"] as! [String: [String: Any]] {
            files[id] = DriveFile(id: id, name: item["name"] as! String, mimeType: item["mimeType"] as! String,
                md5: item["md5"] as? String, parents: item["parents"] as! [String],
                modifiedTime: (item["modifiedTime"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) })
        }
        contents = (value["contents"] as! [String: [UInt8]]).mapValues { Data($0) }
        calls = value["calls"] as! [String]
        uploadedPaths = value["uploaded_paths"] as! [String]
        deletedPaths = value["deleted_paths"] as! [String]
        failures = Set(value["failures"] as! [String])
    }

}

/// 기존 가짜 드라이브를 메인 실행기 뒤에 두어 동기 콜백의 교착을 드러낸다.
@MainActor
final class MainActorDrive: DriveAPI {
    private let drive: FakeDrive
    init(_ drive: FakeDrive) { self.drive = drive }
    func list() async throws -> [DriveFile] { try await drive.list() }
    func download(id: String) async throws -> Data { try await drive.download(id: id) }
    func upload(name: String, parentID: String?, data: Data) async throws -> DriveFile { try await drive.upload(name: name, parentID: parentID, data: data) }
    func update(id: String, data: Data) async throws -> DriveFile { try await drive.update(id: id, data: data) }
    func createFolder(name: String, parentID: String?) async throws -> DriveFile { try await drive.createFolder(name: name, parentID: parentID) }
    func delete(id: String) async throws { try await drive.delete(id: id) }
}
