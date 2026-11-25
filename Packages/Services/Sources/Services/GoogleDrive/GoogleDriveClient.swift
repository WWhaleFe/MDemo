import Foundation

/// 드라이브 v3 REST 호출. 재시도 규칙: 401이면 토큰을 새로 받아 1번, 403(rateLimit) · 429 · 5xx는 지수 백오프로 최대 5번.
public struct GoogleDriveClient: DriveAPI {
    public static let maxRetries = 5
    private static let fields = "id,name,mimeType,md5Checksum,parents,modifiedTime"
    private static let apiBase = "https://www.googleapis.com/drive/v3/files"
    private static let uploadBase = "https://www.googleapis.com/upload/drive/v3/files"

    private let tokens: any AccessTokenProvider
    private let transport: any HTTPTransport
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        tokens: any AccessTokenProvider,
        transport: any HTTPTransport = GoogleHTTP(),
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.tokens = tokens
        self.transport = transport
        self.sleep = sleep
    }

    // MARK: - DriveAPI

    public func list() async throws -> [DriveFile] {
        var files: [DriveFile] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: Self.apiBase)!
            var items = [
                URLQueryItem(name: "q", value: "trashed=false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fields))"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "spaces", value: "drive"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = items
            let data = try await perform { token in Self.request(components.url!, method: "GET", token: token) }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw DriveError.invalidResponse }
            for entry in json["files"] as? [[String: Any]] ?? [] {
                if let file = Self.parse(entry) { files.append(file) }
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return files
    }

    public func download(id: String) async throws -> Data {
        var components = URLComponents(string: "\(Self.apiBase)/\(id)")!
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]
        return try await perform { token in Self.request(components.url!, method: "GET", token: token) }
    }

    public func upload(name: String, parentID: String?, data: Data) async throws -> DriveFile {
        var metadata: [String: Any] = ["name": name]
        if let parentID { metadata["parents"] = [parentID] }
        return try await multipart(url: Self.uploadURL(id: nil), method: "POST", metadata: metadata, data: data)
    }

    public func update(id: String, data: Data) async throws -> DriveFile {
        try await multipart(url: Self.uploadURL(id: id), method: "PATCH", metadata: [:], data: data)
    }

    public func createFolder(name: String, parentID: String?) async throws -> DriveFile {
        var metadata: [String: Any] = ["name": name, "mimeType": DriveFile.folderMimeType]
        if let parentID { metadata["parents"] = [parentID] }
        var components = URLComponents(string: Self.apiBase)!
        components.queryItems = [URLQueryItem(name: "fields", value: Self.fields)]
        let body = try JSONSerialization.data(withJSONObject: metadata)
        let data = try await perform { token in
            var request = Self.request(components.url!, method: "POST", token: token)
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        return try Self.parseResponse(data)
    }

    /// 휴지통으로 보내지 않고 영구 삭제한다.
    public func delete(id: String) async throws {
        let url = URL(string: "\(Self.apiBase)/\(id)")!
        _ = try await perform { token in Self.request(url, method: "DELETE", token: token) }
    }

    // MARK: - 내부

    private static func uploadURL(id: String?) -> URL {
        var components = URLComponents(string: id.map { "\(uploadBase)/\($0)" } ?? uploadBase)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: fields),
        ]
        return components.url!
    }

    private func multipart(url: URL, method: String, metadata: [String: Any], data: Data) async throws -> DriveFile {
        let boundary = "mdemo-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--".utf8))
        let payload = body
        let response = try await perform { token in
            var request = Self.request(url, method: method, token: token)
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return request
        }
        return try Self.parseResponse(response)
    }

    private static func request(_ url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// 요청 하나를 재시도 규칙에 따라 보낸다.
    private func perform(_ build: (String) -> URLRequest) async throws -> Data {
        var refreshed = false
        var retries = 0
        while true {
            let token = try await tokens.accessToken(forceRefresh: refreshed)
            let result = try await transport.send(build(token))
            switch result.status {
            case 200..<300:
                return result.data
            case 401 where !refreshed:
                refreshed = true
                continue
            case 404:
                throw DriveError.notFound
            default:
                if Self.isRetryable(result), retries < Self.maxRetries {
                    // 1, 2, 4, 8, 16초에 약간의 흔들림을 더한다.
                    await sleep(pow(2, Double(retries)) + Double.random(in: 0...0.5))
                    retries += 1
                    continue
                }
                throw DriveError.http(result.status, String(data: result.data.prefix(300), encoding: .utf8) ?? "")
            }
        }
    }

    private static func isRetryable(_ result: HTTPResult) -> Bool {
        switch result.status {
        case 429, 500..<600: return true
        case 403:
            let text = String(data: result.data, encoding: .utf8) ?? ""
            return text.contains("ateLimit")
        default: return false
        }
    }

    private static func parseResponse(_ data: Data) throws -> DriveFile {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let file = parse(json) else {
            throw DriveError.invalidResponse
        }
        return file
    }

    private static func parse(_ json: [String: Any]) -> DriveFile? {
        guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        return DriveFile(
            id: id,
            name: name,
            mimeType: json["mimeType"] as? String ?? "application/octet-stream",
            md5: json["md5Checksum"] as? String,
            parents: json["parents"] as? [String] ?? [],
            modifiedTime: (json["modifiedTime"] as? String).flatMap(parseDate)
        )
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
