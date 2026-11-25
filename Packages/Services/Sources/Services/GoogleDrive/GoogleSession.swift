import Foundation

/// 드라이브 호출에 쓸 access token을 내준다.
public protocol AccessTokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

/// 구글 로그인 상태. refresh token은 키체인에만, access token은 메모리에만 둔다.
public actor GoogleSession: AccessTokenProvider {
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"
    private static let userInfoEndpoint = "https://openidconnect.googleapis.com/v1/userinfo"
    /// 만료 1분 전부터는 새로 받는다.
    private static let refreshMargin: TimeInterval = 60

    private let config: GoogleOAuthConfig
    private let store: any GoogleTokenStore
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var cachedToken: String?
    private var expiry: Date = .distantPast

    public init(
        config: GoogleOAuthConfig,
        store: any GoogleTokenStore,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.store = store
        self.transport = transport
        self.now = now
    }

    // MARK: - 로그인

    /// 브라우저로 로그인하고 이메일을 돌려준다. 성공하면 refresh token을 키체인에 저장한다.
    public func signIn(openBrowser: @Sendable (URL) -> Void) async throws -> String {
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeState()
        let receiver = try await LoopbackReceiver.start()
        do {
            let url = PKCE.authorizationURL(
                clientID: config.clientID,
                redirectURI: receiver.redirectURI,
                challenge: PKCE.challenge(for: verifier),
                state: state
            )
            openBrowser(url)
            let query = try await receiver.waitForRequest()

            guard query["state"] == state else { throw GoogleAuthError.stateMismatch }
            if let reason = query["error"] { throw GoogleAuthError.denied(reason) }
            guard let code = query["code"], !code.isEmpty else { throw GoogleAuthError.missingCode }

            let tokens = try await exchange(code: code, verifier: verifier, redirectURI: receiver.redirectURI)
            guard let refresh = tokens.refreshToken else { throw GoogleAuthError.missingRefreshToken }
            let email = try await resolveEmail(idToken: tokens.idToken, accessToken: tokens.accessToken)
            try store.save(GoogleCredentials(email: email, refreshToken: refresh))
            cachedToken = tokens.accessToken
            expiry = now().addingTimeInterval(tokens.expiresIn)
            receiver.respond(success: true, message: "", service: "구글 드라이브")
            return email
        } catch {
            receiver.respond(success: false, message: error.localizedDescription, service: "구글 드라이브")
            throw error
        }
    }

    private struct TokenResponse {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiresIn: TimeInterval
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ])
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var all = fields
        all["client_id"] = config.clientID
        all["client_secret"] = config.clientSecret
        var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(all).utf8)
        let result = try await transport.send(request)
        let json = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any]
        guard (200..<300).contains(result.status), let access = json?["access_token"] as? String else {
            let reason = json?["error"] as? String ?? "HTTP \(result.status)"
            if fields["grant_type"] == "refresh_token", reason == "invalid_grant" { throw GoogleAuthError.reauthRequired }
            throw GoogleAuthError.tokenExchangeFailed(reason)
        }
        return TokenResponse(
            accessToken: access,
            refreshToken: json?["refresh_token"] as? String,
            idToken: json?["id_token"] as? String,
            expiresIn: (json?["expires_in"] as? Double) ?? 3600
        )
    }

    /// id_token의 email을 먼저 보고, 없으면 userinfo로 묻는다.
    private func resolveEmail(idToken: String?, accessToken: String) async throws -> String {
        if let email = Self.email(fromIDToken: idToken) { return email }
        var request = URLRequest(url: URL(string: Self.userInfoEndpoint)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let result = try await transport.send(request)
        let json = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any]
        guard (200..<300).contains(result.status), let email = json?["email"] as? String, !email.isEmpty else {
            throw GoogleAuthError.tokenExchangeFailed("이메일을 확인하지 못했습니다")
        }
        return email
    }

    static func email(fromIDToken token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let email = json["email"] as? String, !email.isEmpty
        else { return nil }
        return email
    }

    // MARK: - access token

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cachedToken, expiry.timeIntervalSince(now()) > Self.refreshMargin {
            return cachedToken
        }
        guard let credentials = try store.load() else { throw GoogleAuthError.notSignedIn }
        let tokens = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
        ])
        cachedToken = tokens.accessToken
        expiry = now().addingTimeInterval(tokens.expiresIn)
        return tokens.accessToken
    }

    // MARK: - 로그아웃

    /// 토큰 폐기를 시도하고(실패해도 진행) 키체인 항목을 지운다.
    public func signOut() async throws {
        if let credentials = try? store.load() {
            var request = URLRequest(url: URL(string: Self.revokeEndpoint)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formEncode(["token": credentials.refreshToken]).utf8)
            _ = try? await transport.send(request)
        }
        cachedToken = nil
        expiry = .distantPast
        try store.delete()
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}
