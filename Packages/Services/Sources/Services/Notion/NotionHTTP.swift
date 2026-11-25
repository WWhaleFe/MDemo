import Foundation

/// 노션 API와 중계 서버에 실제로 통신하는 유일한 곳 (구글 · 업데이트 확인 제외).
/// 쿠키와 캐시를 남기지 않는 임시 세션을 쓴다. 이미지 올리기가 있어 시간 제한은 넉넉하게 둔다.
public struct NotionHTTP: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return HTTPResult(status: http.statusCode, data: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
    }
}
