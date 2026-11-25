import Foundation
import MemoCore

/// 메모 ID → 올라간 노션 페이지 연결 기록. 다시 올릴 때 같은 페이지를 갱신하는 데 쓴다.
///
/// 이 맥에만 두는 파일이다. 데이터 폴더 밖에 있어 iCloud · 드라이브 동기화와 백업에 들어가지 않는다.
public final class NotionLinkStore: @unchecked Sendable {
    public struct Link: Sendable, Equatable, Codable {
        public var pageID: String
        /// 이 페이지를 만든 올릴 곳. 올릴 곳을 바꾸면 새로 만든다.
        public var targetID: String
        /// 제목을 갱신할 속성 이름 (페이지 아래면 "title").
        public var titleProperty: String

        public init(pageID: String, targetID: String, titleProperty: String) {
            self.pageID = pageID
            self.targetID = targetID
            self.titleProperty = titleProperty
        }
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(AppStorageName.folder)/notion-links.json")
    }

    public func link(for id: MemoID) -> Link? {
        lock.withLock { read()[id.rawValue] }
    }

    public func set(_ link: Link, for id: MemoID) {
        lock.withLock {
            var all = read()
            all[id.rawValue] = link
            write(all)
        }
    }

    public func remove(_ id: MemoID) {
        lock.withLock {
            var all = read()
            all[id.rawValue] = nil
            write(all)
        }
    }

    /// 로그아웃할 때 모두 지운다.
    public func removeAll() {
        lock.withLock { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func read() -> [String: Link] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Link].self, from: data)) ?? [:]
    }

    private func write(_ links: [String: Link]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(links) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// 올릴 곳 설정 (UserDefaults `notion.target`).
public struct NotionTargetStore: @unchecked Sendable {
    public static let key = "notion.target"
    private let defaults: UserDefaults
    private let key: String

    /// `key`는 개발용 시험 실행이 실제 설정과 섞이지 않게 바꿀 때만 쓴다.
    public init(defaults: UserDefaults = .standard, key: String = Self.key) {
        self.defaults = defaults
        self.key = key
    }

    public var target: NotionTarget? {
        get {
            guard let dict = defaults.dictionary(forKey: key),
                  let type = (dict["type"] as? String).flatMap(NotionTarget.Kind.init(rawValue:)),
                  let id = dict["id"] as? String, !id.isEmpty
            else { return nil }
            return NotionTarget(type: type, id: id, title: dict["title"] as? String ?? "")
        }
        nonmutating set {
            if let newValue {
                defaults.set(["type": newValue.type.rawValue, "id": newValue.id, "title": newValue.title], forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
