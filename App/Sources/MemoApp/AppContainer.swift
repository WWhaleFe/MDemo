import EditorKit
import Features
import Foundation
import MemoCore
import Services
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
    let preferences: AppPreferences
    let windowRegistry: WindowRegistry
    let listWindow: MemoListWindowController
    let syncCoordinator: SyncCoordinator
    let hotkeys = GlobalHotkeyService()
    let updateChecker: UpdateChecker

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
        self.preferences = AppPreferences()
        self.updateChecker = UpdateChecker(preferences: preferences)

        // 첫 실행에서는 이 화면에서 읽기 편한 값으로 시작한다.
        // 화면 밀도가 제각각이라 고정값을 쓰면 어느 화면에서는 반드시 너무 작거나 크다.
        let recommendation = DisplayMetrics.recommended()
        preferences.applyRecommended(
            fontSize: Double(recommendation.fontSize),
            memoWidth: Double(recommendation.memoSize.width),
            memoHeight: Double(recommendation.memoSize.height)
        )
        let registry = WindowRegistry(
            store: store,
            deviceState: deviceState,
            preferences: preferences
        )
        self.windowRegistry = registry

        // 리스트 창은 메모를 열어 달라고 요청만 하고, 창을 만드는 일은 레지스트리가 한다.
        let listWindow = MemoListWindowController(
            store: store,
            windowActions: MemoWindowActions(
                isVisible: { [registry] id in registry.isVisible(id: id) },
                open: { [registry] ids in registry.openMemos(ids: ids) },
                hide: { [registry] ids in registry.hideMemos(ids: ids) },
                arrange: { [registry] byGroup in registry.arrangeOpenWindows(byGroup: byGroup) }
            ),
            onOpenMemo: { [registry] id in registry.openMemo(id: id) },
            onCreateMemo: { [registry] in registry.createMemo() }
        )
        listWindow.trashRetentionDays = { [preferences] in
            preferences.autoEmptyTrash ? AppPreferences.trashRetentionDays : nil
        }
        self.listWindow = listWindow

        // 창이 뜨거나 지면 리스트 창의 "보이는/숨겨진" 개수도 함께 달라진다.
        registry.onWindowStateChange = { [weak listWindow] in
            listWindow?.refreshIfOpen()
        }

        self.syncCoordinator = SyncCoordinator(
            store: store,
            windowRegistry: registry,
            preferences: preferences
        )

        // 보관 기간이 지난 휴지통 항목을 정리한다 (TRS-03).
        // 메뉴바 앱은 며칠씩 켜 둔 채로 쓰므로 시작할 때 한 번으로는 모자라다. 몇 시간마다 다시 본다.
        purgeExpiredTrash()
        trashPurgeTimer = Timer.scheduledTimer(withTimeInterval: Self.trashPurgeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeExpiredTrash() }
        }
    }

    private var trashPurgeTimer: Timer?
    private static let trashPurgeInterval: TimeInterval = 6 * 60 * 60

    /// 자동 비우기가 꺼져 있으면 아무것도 지우지 않는다.
    func purgeExpiredTrash() {
        guard preferences.autoEmptyTrash else { return }
        store.emptyTrash(olderThan: AppPreferences.trashRetentionDays)
        listWindow.refreshIfOpen()
    }
}
