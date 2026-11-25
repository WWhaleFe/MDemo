import Foundation

public struct HTTPResult: Sendable {
    public var status: Int
    public var data: Data
    /// 서버가 `Retry-After`로 알려 준 대기 초. 없으면 nil.
    public var retryAfter: TimeInterval?

    public init(status: Int, data: Data, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.data = data
        self.retryAfter = retryAfter
    }
}

/// 구글과 통신하는 통로. 시험에서는 가짜로 바꿔 끼운다.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

/// 구글 서버와 실제로 통신하는 유일한 곳 (업데이트 확인 제외).
/// 쿠키와 캐시를 남기지 않는 임시 세션을 쓴다.
public struct GoogleHTTP: HTTPTransport {
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
        return HTTPResult(status: http.statusCode, data: data)
    }
}
