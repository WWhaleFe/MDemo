import Foundation

/// 노션 로그인 상태. 토큰은 키체인에만 두고, 메모리에는 읽은 사본만 둔다.
public actor NotionSession: AccessTokenProvider {
    private let config: NotionOAuthConfig
    private let store: any NotionTokenStore
    private let transport: any HTTPTransport
    private var credentials: NotionCredentials?

    public init(config: NotionOAuthConfig, store: any NotionTokenStore, transport: any HTTPTransport) {
        self.config = config
        self.store = store
        self.transport = transport
        self.credentials = try? store.load()
    }

    /// 로그인된 워크스페이스. 로그아웃 상태면 nil.
    public var current: NotionCredentials? { credentials }

    // MARK: - 로그인

    /// 브라우저로 로그인하고 워크스페이스 정보를 돌려준다. 성공하면 토큰을 키체인에 저장한다.
    public func signIn(openBrowser: @Sendable (URL) -> Void) async throws -> NotionCredentials {
        let receiver = try await LoopbackReceiver.start()
        do {
            let state = NotionAuth.makeState(port: receiver.port)
            openBrowser(NotionAuth.authorizationURL(config: config, state: state))
            let query = try await receiver.waitForRequest()
            let code = try NotionAuth.code(fromCallback: query, path: receiver.requestPath, expectedState: state)
            let tokens = try await tokenRequest(["code": code])
            try store.save(tokens)
            credentials = tokens
            receiver.respond(success: true, message: "")
            return tokens
        } catch {
            receiver.respond(success: false, message: error.localizedDescription)
            throw error
        }
    }

    /// 중계 서버에 코드 또는 갱신 토큰을 보내 노션 토큰을 받는다.
    private func tokenRequest(_ body: [String: String]) async throws -> NotionCredentials {
        guard let url = config.tokenURL else { throw NotionAuthError.tokenExchangeFailed("중계 주소가 올바르지 않습니다") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let result = try await transport.send(request)
        let json = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any]
        guard (200..<300).contains(result.status), let access = json?["access_token"] as? String, !access.isEmpty else {
            let reason = (json?["error"] as? String) ?? "HTTP \(result.status)"
            throw NotionAuthError.tokenExchangeFailed(reason)
        }
        let previous = credentials
        return NotionCredentials(
            accessToken: access,
            refreshToken: (json?["refresh_token"] as? String) ?? (body["refresh_token"]),
            workspaceName: (json?["workspace_name"] as? String) ?? previous?.workspaceName ?? "",
            workspaceID: (json?["workspace_id"] as? String) ?? previous?.workspaceID ?? "",
            botID: (json?["bot_id"] as? String) ?? previous?.botID ?? ""
        )
    }

    // MARK: - access token

    /// `forceRefresh`는 401을 받은 뒤에 쓴다. 갱신 토큰이 없거나 갱신에 실패하면 다시 로그인해야 한다.
    public func accessToken(forceRefresh: Bool) async throws -> String {
        guard let credentials else { throw NotionAuthError.notSignedIn }
        guard forceRefresh else { return credentials.accessToken }
        guard let refresh = credentials.refreshToken, !refresh.isEmpty else { throw NotionAuthError.reauthRequired }
        let renewed: NotionCredentials
        do {
            renewed = try await tokenRequest(["refresh_token": refresh])
        } catch {
            throw NotionAuthError.reauthRequired
        }
        try store.save(renewed)
        self.credentials = renewed
        return renewed.accessToken
    }

    // MARK: - 로그아웃

    /// 키체인 항목을 지운다. 올릴 곳 · 페이지 연결 기록은 호출하는 쪽에서 함께 지운다.
    public func signOut() throws {
        credentials = nil
        try store.delete()
    }
}
