import Foundation
import CoreBridge

/// P7 동안 기본은 Swift다. Rust를 선택하면 그림자를 씌우지 않는다.
public enum CoreStorage {
    public static var usesRust: Bool {
        ProcessInfo.processInfo.arguments.contains("--rust-storage") || Bundle.main.object(forInfoDictionaryKey: "MDemoRustStorage") as? Bool == true
    }

    /// 서비스 엔진도 저장소와 같은 플랫폼 키체인을 사용한다.
    public static func bridgeKeys(_ keys: any MemoKeychain) -> any CoreKeyStore { RepositoryKeyStore(keys) }

    public static func make(root: URL, keychain: any MemoKeychain = DeviceMemoKeychain()) throws -> any MemoRepository {
        RustMarkdownBackend.installIfRequested()
        if usesRust {
            return try RustMemoRepository(rootDirectory: root, keychain: keychain)
        }
        return CoreShadow.wrap(try FileMemoRepository(rootDirectory: root, keychain: keychain), dataRoot: root)
    }
}
