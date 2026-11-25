import CryptoKit
import Foundation
import Security

/// 구글 로그인에 쓰는 설치형 앱 클라이언트 정보. 번들의 `GoogleOAuth.plist`에서 읽는다.
public struct GoogleOAuthConfig: Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// 파일이 없거나 값이 비어 있으면 nil. 이때는 구글 로그인 기능을 끈다.
    public static func load(from bundle: Bundle = .main) -> GoogleOAuthConfig? {
        guard let url = bundle.url(forResource: "GoogleOAuth", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let id = (plist["CLIENT_ID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = (plist["CLIENT_SECRET"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return GoogleOAuthConfig(clientID: id, clientSecret: secret)
    }
}

/// PKCE(RFC 7636)와 인증 주소 만들기.
public enum PKCE {
    public static let scope = "https://www.googleapis.com/auth/drive.file openid email"
    public static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"

    /// 43~128자 무작위 문자열. 바이트 48개를 base64url로 쓰면 64자다.
    public static func makeVerifier() -> String {
        base64URL(randomBytes(48))
    }

    public static func makeState() -> String {
        base64URL(randomBytes(24))
    }

    /// code_challenge = base64url(SHA256(verifier))
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func authorizationURL(clientID: String, redirectURI: String, challenge: String, state: String) -> URL {
        var components = URLComponents(string: authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }
}

public enum GoogleAuthError: Error, LocalizedError, Equatable {
    case stateMismatch
    case denied(String)
    case missingCode
    case timedOut
    case tokenExchangeFailed(String)
    case missingRefreshToken
    case reauthRequired
    case notSignedIn
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .stateMismatch: return "로그인 요청이 맞지 않아 중단했습니다. 다시 시도해 주세요."
        case .denied(let reason): return "로그인이 거부되었습니다 (\(reason))."
        case .missingCode: return "구글에서 인증 코드를 받지 못했습니다."
        case .timedOut: return "5분 안에 로그인이 끝나지 않아 취소했습니다."
        case .tokenExchangeFailed(let detail): return "구글 로그인 토큰을 받지 못했습니다: \(detail)"
        case .missingRefreshToken: return "구글이 장기 인증 토큰을 주지 않았습니다. 다시 로그인해 주세요."
        case .reauthRequired: return "구글 로그인이 만료되었습니다. 다시 로그인해 주세요."
        case .notSignedIn: return "구글에 로그인되어 있지 않습니다."
        case .keychain(let status): return "키체인 오류 (\(status))"
        }
    }
}

public struct GoogleCredentials: Sendable, Equatable {
    public var email: String
    public var refreshToken: String

    public init(email: String, refreshToken: String) {
        self.email = email
        self.refreshToken = refreshToken
    }
}

/// refresh token 보관소. 시험에서는 메모리 구현을 쓴다.
public protocol GoogleTokenStore: Sendable {
    func load() throws -> GoogleCredentials?
    func save(_ credentials: GoogleCredentials) throws
    func delete() throws
}

/// 이 맥의 키체인에만 둔다 (iCloud 키체인 동기화 끔).
/// 보호 키체인은 팀 ID 서명이 필요해 애드혹 서명에서는 -34018이 난다. 그때는 로그인 키체인으로 되돌아간다.
public struct KeychainGoogleTokenStore: GoogleTokenStore {
    public static let service = "com.wwhalefe.MDemo.google"
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

    public func load() throws -> GoogleCredentials? {
        for dataProtection in [true, false] {
            var request = baseQuery(dataProtection: dataProtection)
            request[kSecReturnData as String] = true
            request[kSecReturnAttributes as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecSuccess, let item = result as? [String: Any],
               let account = item[kSecAttrAccount as String] as? String,
               let data = item[kSecValueData as String] as? Data,
               let token = String(data: data, encoding: .utf8) {
                return GoogleCredentials(email: account, refreshToken: token)
            }
            guard status == errSecSuccess || status == errSecItemNotFound || status == Self.missingEntitlement
            else { throw GoogleAuthError.keychain(status) }
        }
        return nil
    }

    public func save(_ credentials: GoogleCredentials) throws {
        try delete()
        let attributes: [String: Any] = [
            kSecAttrAccount as String: credentials.email,
            kSecValueData as String: Data(credentials.refreshToken.utf8),
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
        guard status == errSecSuccess else { throw GoogleAuthError.keychain(status) }
    }

    /// 두 키체인 모두에서 지운다. 항목이 없거나 보호 키체인을 쓸 수 없는 것은 성공으로 본다.
    public func delete() throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || (dataProtection && status == Self.missingEntitlement)
            else { throw GoogleAuthError.keychain(status) }
        }
    }
}
