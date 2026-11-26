import Foundation

/// P7 동안 기본은 Swift다. Rust를 선택하면 그림자를 씌우지 않는다.
public enum CoreStorage {
    public static func make(root: URL, keychain: any MemoKeychain = DeviceMemoKeychain()) throws -> any MemoRepository {
        if ProcessInfo.processInfo.arguments.contains("--rust-storage") || Bundle.main.object(forInfoDictionaryKey: "MDemoRustStorage") as? Bool == true {
            return try RustMemoRepository(rootDirectory: root, keychain: keychain)
        }
        return CoreShadow.wrap(try FileMemoRepository(rootDirectory: root, keychain: keychain), dataRoot: root)
    }
}
