import Foundation
import MemoCore
import StickyWindow

/// 의존성 조립 지점. 생성자 주입만 사용하고 DI 프레임워크는 쓰지 않는다.
///
/// 앞으로 추가될 구성요소(M3 리스트 창, M4 SyncService)도 모두 여기서 만들어
/// 아래 계층으로 내려보낸다. 전역 싱글턴을 만들지 않는 이유는
/// 테스트 가능성과 수명 관리(메모리 회수) 때문이다.
@MainActor
final class AppContainer {
    let store: MemoStore
    let deviceState: DeviceStateStore
    let windowRegistry: WindowRegistry

    init() {
        let repository: any MemoRepository
        do {
            repository = try FileMemoRepository(rootDirectory: FileMemoRepository.defaultRootDirectory())
        } catch {
            // 데이터 폴더를 만들지 못하면 메모를 저장할 수 없다. 조용히 실패하면 더 위험하다.
            fatalError("데이터 폴더를 만들 수 없습니다: \(error)")
        }

        self.store = MemoStore(repository: repository)
        self.deviceState = DeviceStateStore(fileURL: DeviceStateStore.defaultFileURL())
        self.windowRegistry = WindowRegistry(store: store, deviceState: deviceState)
    }
}
