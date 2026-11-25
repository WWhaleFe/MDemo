import Foundation
import Security

/// 노션 로그인 설정. 번들의 `NotionOAuth.plist`에서 읽는다. 비밀키는 여기에 없고 중계 서버에만 있다.
public struct NotionOAuthConfig: Sendable, Equatable {
    public var clientID: String
    /// 중계 서버 주소 (끝의 `/` 없이). 예: `https://example.vercel.app`
    public var relayURL: String

    public init(clientID: String, relayURL: String) {
        self.clientID = clientID
        var url = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        self.relayURL = url
    }

    /// 중계 서버가 노션에서 코드를 받는 주소. 노션 통합의 Redirect URI와 같아야 한다.
    public var redirectURI: String { relayURL + "/api/notion/callback" }
    public var tokenURL: URL? { URL(string: relayURL + "/api/notion/token") }

    /// 파일이 없거나 값이 비어 있으면 nil. 이때는 노션 기능을 끈다.
    public static func load(from bundle: Bundle = .main) -> NotionOAuthConfig? {
        guard let url = bundle.url(forResource: "NotionOAuth", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let id = (plist["CLIENT_ID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let relay = (plist["RELAY_URL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, URL(string: relay)?.scheme?.hasPrefix("http") == true else { return nil }
        return NotionOAuthConfig(clientID: id, relayURL: relay)
    }
}

/// 인증 주소와 state 만들기 · 확인.
public enum NotionAuth {
    public static let authEndpoint = "https://api.notion.com/v1/oauth/authorize"
    /// 브라우저가 돌아오는 루프백 경로. 중계 서버(callback.js)와 같아야 한다.
    public static let loopbackPath = "/notion"

    /// "<포트>.<무작위 32자 base64url>". 중계 서버는 포트만 꺼내 쓰고 값은 그대로 돌려보낸다.
    public static func makeState(port: UInt16) -> String {
        "\(port)." + PKCE.base64URL(randomBytes(24))
    }

    public static func authorizationURL(config: NotionOAuthConfig, state: String) -> URL {
        var components = URLComponents(string: authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "owner", value: "user"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// 루프백으로 돌아온 요청을 확인하고 코드를 꺼낸다. 경로나 state가 다르면 거부한다.
    public static func code(fromCallback query: [String: String], path: String, expectedState: String) throws -> String {
        guard path == loopbackPath, query["state"] == expectedState else { throw NotionAuthError.stateMismatch }
        if let reason = query["error"] { throw NotionAuthError.denied(reason) }
        guard let code = query["code"], !code.isEmpty else { throw NotionAuthError.missingCode }
        return code
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }
}

public enum NotionAuthError: Error, LocalizedError, Equatable {
    case stateMismatch
    case denied(String)
    case missingCode
    case tokenExchangeFailed(String)
    case reauthRequired
    case notSignedIn
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .stateMismatch: return "로그인 요청이 맞지 않아 중단했습니다. 다시 시도해 주세요."
        case .denied(let reason): return "노션 로그인이 거부되었습니다 (\(reason))."
        case .missingCode: return "노션에서 인증 코드를 받지 못했습니다."
        case .tokenExchangeFailed(let detail): return "노션 로그인 토큰을 받지 못했습니다: \(detail)"
        case .reauthRequired: return "노션 로그인이 만료되었습니다. 다시 로그인해 주세요."
        case .notSignedIn: return "노션에 로그인되어 있지 않습니다."
        case .keychain(let status): return "키체인 오류 (\(status))"
        }
    }
}

public struct NotionCredentials: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var workspaceName: String
    public var workspaceID: String
    public var botID: String

    public init(accessToken: String, refreshToken: String? = nil, workspaceName: String, workspaceID: String, botID: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.workspaceName = workspaceName
        self.workspaceID = workspaceID
        self.botID = botID
    }
}

/// 노션 토큰 보관소. 시험에서는 메모리 구현을 쓴다.
public protocol NotionTokenStore: Sendable {
    func load() throws -> NotionCredentials?
    func save(_ credentials: NotionCredentials) throws
    func delete() throws
}

/// 이 맥의 키체인에만 둔다 (계정 = workspace_id, iCloud 키체인 동기화 끔).
/// 보호 키체인은 팀 ID 서명이 필요해 애드혹 서명에서는 -34018이 난다. 그때는 로그인 키체인으로 되돌아간다.
public struct KeychainNotionTokenStore: NotionTokenStore {
    public static let service = "com.wwhalefe.MDemo.notion"
    private static let missingEntitlement: OSStatus = -34018
    private let serviceName: String

    /// `serviceName`은 개발용 시험 실행이 실제 로그인과 섞이지 않게 바꿀 때만 쓴다.
    public init(serviceName: String = Self.service) {
        self.serviceName = serviceName
    }

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: false,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    public func load() throws -> NotionCredentials? {
        for dataProtection in [true, false] {
            var request = baseQuery(dataProtection: dataProtection)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data,
               let credentials = try? JSONDecoder().decode(NotionCredentials.self, from: data) {
                return credentials
            }
            guard status == errSecSuccess || status == errSecItemNotFound || status == Self.missingEntitlement
            else { throw NotionAuthError.keychain(status) }
        }
        return nil
    }

    public func save(_ credentials: NotionCredentials) throws {
        try delete()
        let attributes: [String: Any] = [
            kSecAttrAccount as String: credentials.workspaceID,
            kSecValueData as String: try JSONEncoder().encode(credentials),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var request = baseQuery(dataProtection: true)
        request.merge(attributes) { _, new in new }
        var status = SecItemAdd(request as CFDictionary, nil)
        if status == Self.missingEntitlement {
            var fallback = baseQuery(dataProtection: false)
            fallback.merge(attributes) { _, new in new }
            status = SecItemAdd(fallback as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NotionAuthError.keychain(status) }
    }

    /// 두 키체인 모두에서 지운다. 항목이 없거나 보호 키체인을 쓸 수 없는 것은 성공으로 본다.
    public func delete() throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || (dataProtection && status == Self.missingEntitlement)
            else { throw NotionAuthError.keychain(status) }
        }
    }
}
