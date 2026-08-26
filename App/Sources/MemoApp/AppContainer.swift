import Foundation
import StickyWindow

/// 의존성 조립 지점. 생성자 주입만 사용하고 DI 프레임워크는 쓰지 않는다.
///
/// 앞으로 추가될 구성요소(M1 MemoStore, M3 리스트 창, M4 SyncService)는 모두
/// 여기서 만들어 아래 계층으로 내려보낸다. 전역 싱글턴을 만들지 않는 이유는
/// 테스트 가능성과 수명 관리(메모리 회수) 때문이다.
@MainActor
final class AppContainer {
    let windowRegistry: WindowRegistry

    init() {
        self.windowRegistry = WindowRegistry()
    }
}
