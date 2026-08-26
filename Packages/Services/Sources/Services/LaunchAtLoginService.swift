import Foundation
import ServiceManagement

/// 로그인할 때 자동으로 실행되게 한다 (SYS-03).
///
/// 메뉴바에 늘 떠 있어야 쓸모가 있는 앱이라, 켤 때마다 손으로 실행하는 것은 번거롭다.
/// macOS 13부터는 `SMAppService`로 앱이 스스로 등록할 수 있다.
public enum LaunchAtLoginService {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 등록 상태를 바꾼다. 실패하면 이유를 돌려준다.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                // 이미 등록돼 있으면 다시 등록하지 않는다. 중복 등록은 오류가 된다.
                guard SMAppService.mainApp.status != .enabled else { return .success(()) }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// 사용자가 시스템 설정에서 막아 둔 경우.
    public static var isBlockedBySystemSettings: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
