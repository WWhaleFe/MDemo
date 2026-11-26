import Foundation

/// 앱과 화면이 함께 쓰는 설정 저장소. 시험 실행은 실제 앱 설정과 분리한다.
public enum AppSettings {
    public static var defaults: UserDefaults {
        defaults(arguments: CommandLine.arguments)
    }

    /// 실행 인자를 받아 저장소를 선택하므로 실제 앱 도메인을 쓰지 않고도 시험할 수 있다.
    public static func defaults(arguments: [String]) -> UserDefaults {
        guard arguments.contains(where: { $0.hasPrefix("--data-dir=") }) else { return .standard }
        // 별도 suite도 NSArgumentDomain을 읽으므로 실행 인자의 설정 덮어쓰기를 유지한다.
        guard let defaults = UserDefaults(suiteName: "com.wwhalefe.MDemo.devtest") else {
            preconditionFailure("시험용 설정 저장소를 만들 수 없습니다")
        }
        return defaults
    }
}
