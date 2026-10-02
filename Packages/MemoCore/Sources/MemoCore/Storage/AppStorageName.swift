import Foundation

/// 앱이 디스크에 쓰는 폴더 이름.
///
/// Application Support와 iCloud Drive 안의 폴더가 모두 이 이름을 쓴다.
/// 앱 이름을 MemoApp에서 MDemo로 바꾸면서, 예전 이름은 옮겨 오기(LegacyMigration)에만 남긴다.
public enum AppStorageName {
    public static let folder = "MDemo"
    /// 0.9.0까지 쓰던 이름. 처음 실행할 때 이 폴더에서 새 폴더로 복사해 온다.
    public static let legacyFolder = "MemoApp"
}
