import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let container = AppContainer()
        self.container = container
        self.menuBarController = MenuBarController(windowRegistry: container.windowRegistry)

        // `open -a MemoApp --args --new-memo` 로 실행하면 곧바로 새 메모를 띄운다.
        // 인자를 반복하면 그 수만큼 만들어지므로 메모리 측정(§4-5 게이트)에도 쓴다.
        // 이후 전역 단축키(KEY-11)와 외부 실행 경로에서 같은 진입점을 재사용한다.
        let requestedMemoCount = CommandLine.arguments.filter { $0 == "--new-memo" }.count
        for _ in 0..<requestedMemoCount {
            container.windowRegistry.createMemo()
        }
    }

    /// 창을 모두 닫아도 메뉴바에 남아 있어야 한다 (ALM-06, SYS-01).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
