import Foundation

/// 드라이브 안의 파일 하나(폴더 포함).
public struct DriveFile: Sendable, Equatable {
    public static let folderMimeType = "application/vnd.google-apps.folder"

    public var id: String
    public var name: String
    public var mimeType: String
    public var md5: String?
    public var parents: [String]
    public var modifiedTime: Date?

    public init(id: String, name: String, mimeType: String = "application/octet-stream", md5: String? = nil, parents: [String] = [], modifiedTime: Date? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.md5 = md5
        self.parents = parents
        self.modifiedTime = modifiedTime
    }

    public var isFolder: Bool { mimeType == Self.folderMimeType }

    /// 내용이 바뀌었는지 가리는 값. md5가 없으면 수정 시각으로 대신한다.
    public var changeToken: String {
        if let md5, !md5.isEmpty { return md5 }
        return "t:" + String(modifiedTime?.timeIntervalSince1970 ?? 0)
    }
}

public enum DriveError: Error, LocalizedError, Equatable {
    case notFound
    case http(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notFound: return "드라이브에서 파일을 찾을 수 없습니다."
        case .http(let status, let message): return "구글 드라이브 오류 (\(status)) \(message)"
        case .invalidResponse: return "구글 드라이브의 응답을 읽지 못했습니다."
        }
    }
}

/// 드라이브 v3 중 쓰는 기능만. 지울 때는 휴지통을 거치지 않는 영구 삭제(`delete`)만 있다.
public protocol DriveAPI: Sendable {
    /// 휴지통이 아닌 모든 파일(앱이 만든 것만 보인다). 페이지 끝까지.
    func list() async throws -> [DriveFile]
    func download(id: String) async throws -> Data
    /// `parentID`가 nil이면 드라이브 최상위에 만든다.
    func upload(name: String, parentID: String?, data: Data) async throws -> DriveFile
    func update(id: String, data: Data) async throws -> DriveFile
    func createFolder(name: String, parentID: String?) async throws -> DriveFile
    func delete(id: String) async throws
}
