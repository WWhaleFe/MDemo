import Foundation

/// 메모를 올릴 곳. 페이지(그 아래 하위 페이지로) 또는 데이터베이스(새 항목으로).
public struct NotionTarget: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case page, database }
    public var type: Kind
    public var id: String
    public var title: String

    public init(type: Kind, id: String, title: String) {
        self.type = type
        self.id = id
        self.title = title
    }

    public var kindLabel: String { type == .page ? "페이지" : "데이터베이스" }
}

/// 올릴 곳 고르기 목록의 한 줄.
public struct NotionSearchItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var type: NotionTarget.Kind
    public var title: String
    /// 상위 경로. 알 수 없으면 빈 문자열.
    public var path: String

    public init(id: String, type: NotionTarget.Kind, title: String, path: String = "") {
        self.id = id
        self.type = type
        self.title = title
        self.path = path
    }

    public var target: NotionTarget { NotionTarget(type: type, id: id, title: title) }
}

public struct NotionPage: Sendable, Equatable {
    public var id: String
    public var url: String

    public init(id: String, url: String) {
        self.id = id
        self.url = url
    }
}

public enum NotionError: Error, LocalizedError, Equatable {
    case notFound
    case http(Int, String)
    case invalidResponse
    case reauthRequired
    case notSignedIn
    case noTarget

    public var errorDescription: String? {
        switch self {
        case .notFound: return "노션에서 항목을 찾지 못했습니다."
        case .http(let status, let detail): return "노션 요청이 실패했습니다 (HTTP \(status)) \(detail)"
        case .invalidResponse: return "노션의 응답을 읽지 못했습니다."
        case .reauthRequired: return "노션 로그인이 만료되었습니다. 다시 로그인해 주세요."
        case .notSignedIn: return "노션에 로그인되어 있지 않습니다."
        case .noTarget: return "올릴 곳이 정해지지 않았습니다."
        }
    }
}

/// 업로더가 쓰는 노션 호출. 시험에서는 가짜로 바꿔 끼운다.
public protocol NotionAPI: Sendable {
    func search(query: String) async throws -> [NotionSearchItem]
    /// 데이터베이스의 제목 속성(type == title) 이름.
    func titlePropertyName(databaseID: String) async throws -> String
    /// 새 페이지(제목만, 내용 없음). 대상이 페이지면 하위 페이지, 데이터베이스면 새 항목이다.
    func createPage(target: NotionTarget, titleProperty: String?, title: String) async throws -> NotionPage
    /// 페이지가 있고 휴지통에 있지 않으면 그 정보, 지워졌거나 보관(archived)됐으면 nil.
    func existingPage(id: String) async throws -> NotionPage?
    func updateTitle(pageID: String, titleProperty: String, title: String) async throws
    /// 페이지의 기존 블록을 모두 지운다.
    func clearChildren(pageID: String) async throws
    /// 블록을 뒤에 붙인다. 100개씩 나눠 보낸다.
    func append(pageID: String, blocks: [NotionBlock], uploadedImages: [String: String]) async throws
    /// 이미지를 올리고 file_upload id를 돌려준다.
    func uploadImage(data: Data, fileName: String) async throws -> String
}
