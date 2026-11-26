import CoreBridge
import Foundation
import CryptoKit
import CommonCrypto
import Security

public enum MemoLockError: Error, LocalizedError {
    case invalidPassword, missingKey, wrongPassword, damaged, locked, destroyed, keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .invalidPassword: return "4~6자, 영문 대소문자와 숫자"
        case .missingKey: return "이 맥에서 만든 잠긴 메모가 아니거나 열쇠가 없어 열 수 없습니다"
        case .wrongPassword: return "암호가 맞지 않습니다"
        case .damaged: return "암호 메모가 손상되어 열 수 없습니다"
        case .locked: return "먼저 암호 메모를 열어 주세요"
        case .destroyed: return "이 메모는 파기되었습니다"
        case .keychain: return "이 맥 키체인에 접근하지 못했습니다"
        }
    }
}

public enum LockCrypto {
    public static let minimumIterations = 2_000_000
    public static func validPassword(_ value: String) -> Bool {
        (4...6).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        var left = Array(a.utf8), right = Array(b.utf8)
        defer {
            _ = left.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            _ = right.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        var difference = left.count ^ right.count
        let count = max(left.count, right.count)
        left += repeatElement(0, count: count - left.count)
        right += repeatElement(0, count: count - right.count)
        for index in 0..<count {
            difference |= Int(left[index] ^ right[index])
        }
        return difference == 0
    }
    public static func filteredPassword(_ value: String) -> String {
        String(decoding: value.utf8.filter { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }.prefix(6), as: UTF8.self)
    }
    public static func random(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw MemoLockError.keychain(status) }
        return data
    }
    /// 비교는 AES-GCM 태그 인증에 맡긴다. 암호 문자열을 직접 비교하지 않는다.
    public static func derive(password: String, salt: Data, iterations: Int) throws -> Data {
        guard validPassword(password), salt.count == 16,
              iterations >= minimumIterations, iterations <= 20_000_000 else { throw MemoLockError.damaged }
        var input = Data(password.utf8)
        defer { input.resetBytes(in: 0..<input.count) }
        var result = Data(count: 32)
        let status = result.withUnsafeMutableBytes { output in
            input.withUnsafeBytes { secret in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.baseAddress!.assumingMemoryBound(to: CChar.self), input.count,
                                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), output.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw MemoLockError.damaged }
        return result
    }
    public static func calibratedIterations() -> Int {
        min(20_000_000, max(minimumIterations, Int(CCCalibratePBKDF(CCPBKDFAlgorithm(kCCPBKDF2), 6, 16, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 32, 500))))
    }
    public static func seal(_ plaintext: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32 else { throw MemoLockError.locked }
        return try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: Data(context.utf8)).combined!
    }
    public static func open(_ ciphertext: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32 else { throw MemoLockError.locked }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: key), authenticating: Data(context.utf8))
    }
}

/// 파일에는 감싼 열쇠도 기록하지 않는다. 시험에서는 메모리 구현을 주입한다.
public protocol MemoKeychain: Sendable {
    func read(id: MemoID) throws -> Data?
    func write(_ wrappedKey: Data, id: MemoID) throws
    func delete(id: MemoID) throws
    func readFailures(id: MemoID) throws -> Int
    func writeFailures(_ failures: Int, id: MemoID) throws
}

public struct DeviceMemoKeychain: MemoKeychain {
    public init() {}
    /// 보호 키체인(데이터 보호 키체인)은 팀 ID로 서명한 앱만 쓸 수 있다. 애드혹 서명(지금 배포판)에서는
    /// errSecMissingEntitlement(-34018)가 나므로, 그때는 이 맥의 로그인 키체인에 둔다.
    /// 두 곳 모두 iCloud 키체인 동기화는 끈다(이 맥에만 있음).
    private func query(_ id: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.wwhalefe.MDemo.lock",
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: false]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
    private static let missingEntitlement: OSStatus = -34018

    public func read(id: MemoID) throws -> Data? { try read(account: id.rawValue) }
    private func read(account id: String) throws -> Data? {
        for dataProtection in [true, false] {
            var request = query(id, dataProtection: dataProtection)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecSuccess { return result as? Data }
            guard status == errSecItemNotFound || status == Self.missingEntitlement else { throw MemoLockError.keychain(status) }
        }
        return nil
    }
    public func write(_ wrappedKey: Data, id: MemoID) throws { try write(wrappedKey, account: id.rawValue) }
    private func write(_ wrappedKey: Data, account id: String) throws {
        let status = try write(wrappedKey, account: id, dataProtection: true)
        if status == Self.missingEntitlement {
            let fallback = try write(wrappedKey, account: id, dataProtection: false)
            guard fallback == errSecSuccess else { throw MemoLockError.keychain(fallback) }
        } else if status == errSecSuccess {
            let deleted = SecItemDelete(query(id, dataProtection: false) as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw MemoLockError.keychain(deleted) }
        } else {
            throw MemoLockError.keychain(status)
        }
    }
    private func write(_ wrappedKey: Data, account id: String, dataProtection: Bool) throws -> OSStatus {
        let attributes: [String: Any] = [kSecValueData as String: wrappedKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var request = query(id, dataProtection: dataProtection)
        let updated = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if updated != errSecItemNotFound { return updated }
        request.merge(attributes) { _, new in new }
        return SecItemAdd(request as CFDictionary, nil)
    }
    /// 두 키체인 모두에서 지운다. 항목이 없거나 보호 키체인을 쓸 수 없는 것은 성공으로 본다.
    public func readFailures(id: MemoID) throws -> Int {
        guard let data = try read(account: id.rawValue + ".failures") else { return 0 }
        guard let text = String(data: data, encoding: .utf8), let count = Int(text), count >= 0 else { throw MemoLockError.damaged }
        return count
    }
    public func writeFailures(_ failures: Int, id: MemoID) throws {
        try write(Data(String(failures).utf8), account: id.rawValue + ".failures")
    }
    public func delete(id: MemoID) throws {
        try delete(account: id.rawValue)
        try delete(account: id.rawValue + ".failures")
    }
    private func delete(account id: String) throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(query(id, dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || (dataProtection && status == Self.missingEntitlement)
            else { throw MemoLockError.keychain(status) }
        }
    }
}

/// 열려 있는 창의 열쇠. 이미지 작업과 잠금이 겹쳐도 잠근 뒤 평문을 쓰지 못하게 직렬화한다.
public final class MemoLockSession: @unchecked Sendable {
    private let mutex = NSLock()
    private var key: Data
    private let rust: CoreLockSession?
    public let id: MemoID
    public init(id: MemoID, key: Data) { self.id = id; self.key = key; self.rust = nil }
    init(id: MemoID, rust: CoreLockSession) { self.id = id; self.key = Data(); self.rust = rust }
    private func rustCall<T>(_ action: () throws -> T) throws -> T {
        do { return try action() }
        catch let error as CoreRepositoryError { throw RustMemoRepository.convert(error) }
    }
    public func seal(_ data: Data, name: String? = nil) throws -> Data {
        mutex.lock(); defer { mutex.unlock() }
        if let rust { return try rustCall { try rust.seal(data: data, name: name) } }
        return try LockCrypto.seal(data, key: key, context: id.rawValue + (name.map { "/attachment/" + $0 } ?? "/body"))
    }
    public func open(_ data: Data, name: String? = nil) throws -> Data {
        mutex.lock(); defer { mutex.unlock() }
        if let rust { return try rustCall { try rust.open(data: data, name: name) } }
        return try LockCrypto.open(data, key: key, context: id.rawValue + (name.map { "/attachment/" + $0 } ?? "/body"))
    }
    public func wrapped(password: String, salt: Data, iterations: Int) throws -> Data {
        if let rust {
            let secret = RustPassword(password)
            return try secret.use { bytes in try rustCall { try rust.wrapped(password: bytes, salt: salt, iterations: Int64(iterations)) } }
        }
        var kek = try LockCrypto.derive(password: password, salt: salt, iterations: iterations)
        defer { kek.resetBytes(in: 0..<kek.count) }
        mutex.lock(); defer { mutex.unlock() }
        guard key.count == 32 else { throw MemoLockError.locked }
        return try LockCrypto.seal(key, key: kek, context: id.rawValue + "/key")
    }
    public func clear() {
        mutex.lock(); defer { mutex.unlock() }
        rust?.clear()
        key.resetBytes(in: 0..<key.count)
        key.removeAll(keepingCapacity: false)
    }
    deinit { clear() }
}
