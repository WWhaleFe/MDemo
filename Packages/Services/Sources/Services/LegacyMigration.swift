import Foundation
import MemoCore

/// 앱 이름을 MemoApp에서 MDemo로 바꾸면서 생긴 옮겨 오기.
///
/// 이름과 함께 앱 식별자(com.wwhalefe.MemoApp → com.wwhalefe.MDemo)와 저장 폴더가 바뀌었다.
/// 그대로 두면 새 앱은 메모도 설정도 없는 빈 상태로 뜬다. 처음 실행할 때 한 번 예전 자리에서 복사해 온다.
///
/// 원본은 지우지 않는다. 옮기다 실패하거나 예전 버전으로 돌아가도 메모가 남아 있어야 한다.
/// 새 자리에 이미 무언가 있으면 건드리지 않는다 — 새 앱에서 쓴 내용을 덮어쓰면 안 된다.
public enum LegacyMigration {
    /// 예전 앱 식별자. 이 이름의 사용자 기본값에 예전 설정이 들어 있다.
    public static let legacyBundleIdentifier = "com.wwhalefe.MemoApp"
    private static let defaultsDoneKey = "migration.fromMemoApp.done"

    public struct Report: Equatable, Sendable {
        public var copiedLocalData = false
        public var copiedICloudData = false
        public var copiedSettingsCount = 0
        public var errors: [String] = []
    }

    /// - Parameters:
    ///   - applicationSupport: `~/Library/Application Support`
    ///   - iCloudDrive: iCloud Drive 최상위 폴더. 꺼져 있으면 nil.
    ///   - legacyDefaults: 예전 앱의 사용자 기본값 (`persistentDomain(forName:)`). 없으면 nil.
    ///   - defaults: 새 앱의 사용자 기본값.
    @discardableResult
    public static func run(
        applicationSupport: URL,
        iCloudDrive: URL?,
        legacyDefaults: [String: Any]?,
        defaults: UserDefaults,
        fileManager: FileManager = .default
    ) -> Report {
        var report = Report()

        report.copiedLocalData = copyFolderIfNeeded(
            in: applicationSupport, fileManager: fileManager, errors: &report.errors
        )
        if let iCloudDrive {
            report.copiedICloudData = copyFolderIfNeeded(
                in: iCloudDrive, fileManager: fileManager, errors: &report.errors
            )
        }

        // 설정은 한 번만 옮긴다. 옮긴 뒤 사용자가 바꾼 값을 다음 실행에서 예전 값으로 되돌리면 안 된다.
        if !defaults.bool(forKey: defaultsDoneKey) {
            for (key, value) in legacyDefaults ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                report.copiedSettingsCount += 1
            }
            defaults.set(true, forKey: defaultsDoneKey)
        }
        return report
    }

    /// `parent/MemoApp`을 `parent/MDemo`로 복사한다. 복사했으면 true.
    private static func copyFolderIfNeeded(in parent: URL, fileManager: FileManager, errors: inout [String]) -> Bool {
        let source = parent.appendingPathComponent(AppStorageName.legacyFolder, isDirectory: true)
        let destination = parent.appendingPathComponent(AppStorageName.folder, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path)
        else { return false }
        do {
            try fileManager.copyItem(at: source, to: destination)
            return true
        } catch {
            // 반쯤 복사된 폴더가 남으면 다음 실행에서 "이미 있음"으로 보고 건너뛴다. 지워 두고 다음에 다시 시도한다.
            try? fileManager.removeItem(at: destination)
            errors.append("\(source.path): \(error.localizedDescription)")
            return false
        }
    }
}
