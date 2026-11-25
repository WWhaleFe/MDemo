import Foundation

/// 노션 REST 호출. 재시도 규칙: 401이면 토큰을 갱신해 1번, 429 · 5xx는 지수 백오프로 최대 5번(429는 Retry-After 존중).
/// 노션의 403은 권한 문제(restricted_resource)라 기다려도 풀리지 않으므로 바로 실패로 돌려준다.
public struct NotionClient: NotionAPI {
    public static let maxRetries = 5
    static let apiBase = "https://api.notion.com/v1"
    static let version = "2022-06-28"

    private let tokens: any AccessTokenProvider
    private let transport: any HTTPTransport
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        tokens: any AccessTokenProvider,
        transport: any HTTPTransport = NotionHTTP(),
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.tokens = tokens
        self.transport = transport
        self.sleep = sleep
    }

    // MARK: - NotionAPI

    public func search(query: String) async throws -> [NotionSearchItem] {
        var body: [String: Any] = [
            "sort": ["direction": "descending", "timestamp": "last_edited_time"],
            "page_size": 50,
        ]
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { body["query"] = trimmed }
        let json = try await object(method: "POST", path: "/search", body: body)
        return Self.parseSearch(json["results"] as? [[String: Any]] ?? [])
    }

    public func titlePropertyName(databaseID: String) async throws -> String {
        let json = try await object(method: "GET", path: "/databases/\(databaseID)")
        let properties = json["properties"] as? [String: Any] ?? [:]
        for (name, value) in properties {
            if (value as? [String: Any])?["type"] as? String == "title" { return name }
        }
        throw NotionError.invalidResponse
    }

    public func createPage(target: NotionTarget, titleProperty: String?, title: String) async throws -> NotionPage {
        let parent: [String: Any]
        let property: String
        switch target.type {
        case .page:
            parent = ["page_id": target.id]
            property = "title"
        case .database:
            parent = ["database_id": target.id]
            property = titleProperty ?? "title"
        }
        let json = try await object(method: "POST", path: "/pages", body: [
            "parent": parent,
            "properties": Self.titleProperties(name: property, title: title),
        ])
        return try Self.parsePage(json)
    }

    public func existingPage(id: String) async throws -> NotionPage? {
        do {
            let json = try await object(method: "GET", path: "/pages/\(id)")
            if json["archived"] as? Bool == true || json["in_trash"] as? Bool == true { return nil }
            return try Self.parsePage(json)
        } catch NotionError.notFound {
            return nil
        }
    }

    public func updateTitle(pageID: String, titleProperty: String, title: String) async throws {
        _ = try await object(method: "PATCH", path: "/pages/\(pageID)", body: [
            "properties": Self.titleProperties(name: titleProperty, title: title),
        ])
    }

    public func clearChildren(pageID: String) async throws {
        var ids: [String] = []
        var cursor: String?
        repeat {
            var path = "/blocks/\(pageID)/children?page_size=100"
            if let cursor { path += "&start_cursor=\(cursor)" }
            let json = try await object(method: "GET", path: path)
            ids += (json["results"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            cursor = json["has_more"] as? Bool == true ? json["next_cursor"] as? String : nil
        } while cursor != nil
        for id in ids {
            do {
                _ = try await object(method: "DELETE", path: "/blocks/\(id)")
            } catch NotionError.notFound {
                continue  // 이미 지워졌으면 그대로 둔다.
            }
        }
    }

    public func append(pageID: String, blocks: [NotionBlock], uploadedImages: [String: String]) async throws {
        for chunk in NotionBlocks.chunks(blocks) {
            _ = try await object(method: "PATCH", path: "/blocks/\(pageID)/children", body: [
                "children": chunk.map { $0.json(uploadedImages: uploadedImages) },
            ])
        }
    }

    public func uploadImage(data: Data, fileName: String) async throws -> String {
        let contentType = fileName.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
        let created = try await object(method: "POST", path: "/file_uploads", body: [
            "mode": "single_part", "filename": fileName, "content_type": contentType,
        ])
        guard let id = created["id"] as? String else { throw NotionError.invalidResponse }
        let boundary = "mdemo-" + UUID().uuidString
        var form = Data()
        form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        form.append(data)
        form.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let payload = form
        _ = try await perform { token in
            var request = Self.request(path: "/file_uploads/\(id)/send", method: "POST", token: token)
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return request
        }
        return id
    }

    // MARK: - 내부

    private func object(method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let data = try await perform { token in
            var request = Self.request(path: path, method: method, token: token)
            if let payload {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = payload
            }
            return request
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw NotionError.invalidResponse }
        return json
    }

    static func request(path: String, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: apiBase + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        return request
    }

    /// 요청 하나를 재시도 규칙에 따라 보낸다.
    private func perform(_ build: (String) -> URLRequest) async throws -> Data {
        var refreshed = false
        var retries = 0
        while true {
            let token: String
            do {
                token = try await tokens.accessToken(forceRefresh: refreshed)
            } catch NotionAuthError.reauthRequired {
                throw NotionError.reauthRequired
            } catch NotionAuthError.notSignedIn {
                throw NotionError.notSignedIn
            }
            let result = try await transport.send(build(token))
            switch result.status {
            case 200..<300:
                return result.data
            case 401:
                // 한 번만 갱신해 다시 보낸다. 그래도 401이면 다시 로그인해야 한다.
                guard !refreshed else { throw NotionError.reauthRequired }
                refreshed = true
                continue
            case 404:
                throw NotionError.notFound
            case 429, 500..<600:
                if retries < Self.maxRetries {
                    let backoff = pow(2, Double(retries)) + Double.random(in: 0...0.5)
                    await sleep(result.status == 429 ? max(result.retryAfter ?? 0, backoff) : backoff)
                    retries += 1
                    continue
                }
                throw NotionError.http(result.status, Self.message(result.data))
            default:
                throw NotionError.http(result.status, Self.message(result.data))
            }
        }
    }

    private static func message(_ data: Data) -> String {
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let text = json["message"] as? String {
            return String(text.prefix(200))
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }

    // MARK: - 해석

    static func titleProperties(name: String, title: String) -> [String: Any] {
        let items = NotionBlocks.split([NotionRichText(title)]).map(NotionBlock.richTextJSON)
        return [name: ["title": items.isEmpty ? [NotionBlock.richTextJSON(NotionRichText("제목 없음"))] : items]]
    }

    static func parsePage(_ json: [String: Any]) throws -> NotionPage {
        guard let id = json["id"] as? String else { throw NotionError.invalidResponse }
        return NotionPage(id: id, url: json["url"] as? String ?? "")
    }

    static func plainTitle(_ items: Any?) -> String {
        (items as? [[String: Any]] ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    static func parseSearch(_ results: [[String: Any]]) -> [NotionSearchItem] {
        struct Row { var id: String; var type: NotionTarget.Kind; var title: String; var parentID: String?; var parentIsWorkspace: Bool }
        var rows: [Row] = []
        for entry in results {
            guard let id = entry["id"] as? String, let object = entry["object"] as? String,
                  let type = NotionTarget.Kind(rawValue: object) else { continue }
            var title = ""
            if type == .database {
                title = plainTitle(entry["title"])
            } else if let properties = entry["properties"] as? [String: Any] {
                for value in properties.values {
                    if let property = value as? [String: Any], property["type"] as? String == "title" {
                        title = plainTitle(property["title"])
                    }
                }
            }
            let parent = entry["parent"] as? [String: Any]
            let parentID = (parent?["page_id"] as? String) ?? (parent?["database_id"] as? String)
            rows.append(Row(id: id, type: type, title: title, parentID: parentID, parentIsWorkspace: parent?["type"] as? String == "workspace"))
        }
        let titles = Dictionary(rows.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            var path = ""
            if row.parentIsWorkspace {
                path = "워크스페이스"
            } else if let parentID = row.parentID, let name = titles[parentID] {
                path = name.isEmpty ? "제목 없음" : name
            }
            return NotionSearchItem(id: row.id, type: row.type, title: row.title.isEmpty ? "제목 없음" : row.title, path: path)
        }
    }
}
