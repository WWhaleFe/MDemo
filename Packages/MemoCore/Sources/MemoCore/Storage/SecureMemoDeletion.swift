import Foundation
import Darwin

/// 삭제 목록은 합집합으로만 커진다. 복원과 동기화가 파기한 ID를 되살리지 못하게 한다.
public enum MemoPrivacyLedger {
    private static let mutex = NSRecursiveLock()
    public static func read(_ name: String, root: URL) throws -> Set<String> {
        mutex.lock(); defer { mutex.unlock() }
        let url = root.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url))).filter { MemoID(rawValue: $0).isValid }
    }
    public static func write(_ ids: Set<String>, name: String, root: URL) throws {
        mutex.lock(); defer { mutex.unlock() }
        let merged = try ids.union(read(name, root: root))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name + ".json")
        try JSONEncoder().encode(merged.sorted()).write(to: url, options: .atomic)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    public static func insert(_ id: MemoID, name: String, root: URL) throws {
        var ids = try read(name, root: root)
        ids.insert(id.rawValue)
        try write(ids, name: name, root: root)
    }
}

public enum SecureMemoDeletion {
    /// 파일부터 하위 폴더와 부모 폴더까지 디스크에 반영한다.
    public static func synchronize(_ directory: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw MemoLockError.damaged }
            if values.isDirectory == true { try synchronize(entry) }
            else {
                let handle = try FileHandle(forUpdating: entry)
                defer { try? handle.close() }
                try handle.synchronize()
            }
        }
        try synchronizeDirectory(directory)
        try synchronizeDirectory(directory.deletingLastPathComponent())
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }

    /// 심볼릭 링크를 따라가지 않고 같은 길이의 난수로 덮은 뒤 동기화한다.
    /// APFS 스냅샷과 SSD의 물리 블록까지 지웠다고 보장하지는 않는다.
    public static func remove(_ directory: URL, beforeRemoval: ((URL) throws -> Void)? = nil) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        let type = try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType
        if type == .typeSymbolicLink { try fm.removeItem(at: directory); try synchronizeDirectory(directory.deletingLastPathComponent()); return }
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { throw MemoLockError.damaged }
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let fd = Darwin.open(file.path, O_WRONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw POSIXError(.EACCES) }
            do {
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
                guard (info.st_mode & S_IFMT) == S_IFREG else { Darwin.close(fd); continue }
                var remaining = Int64(info.st_size)
                while remaining > 0 {
                    let data = try LockCrypto.random(count: Int(min(remaining, 65536)))
                    try data.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < data.count {
                            let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                            guard written > 0 else { throw POSIXError(.EIO) }
                            offset += written
                        }
                    }
                    remaining -= Int64(data.count)
                }
                guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
                guard ftruncate(fd, 0) == 0 else { throw POSIXError(.EIO) }
                Darwin.close(fd)
            } catch { Darwin.close(fd); throw error }
        }
        try beforeRemoval?(directory)
        try fm.removeItem(at: directory)
        try synchronizeDirectory(directory.deletingLastPathComponent())
    }
    public static func removeCopies(id: MemoID, root: URL) throws {
        for folder in ["memos", "trash"] {
            try remove(root.appendingPathComponent(folder).appendingPathComponent(id.rawValue))
        }
    }
}
