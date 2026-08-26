import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let container = AppContainer()
        self.container = container
        self.menuBarController = MenuBarController(
            windowRegistry: container.windowRegistry,
            store: container.store,
            preferences: container.preferences
        )

        // 지난 실행에서 열려 있던 메모를 그대로 되살린다 (WIN-06).
        container.windowRegistry.restoreOpenMemos()

        // `open -a MemoApp --args --new-memo` 로 실행하면 곧바로 새 메모를 띄운다.
        // 인자를 반복하면 그 수만큼 만들어지므로 메모리 측정(§4-5 게이트)에도 쓴다.
        // 이후 전역 단축키(KEY-11)와 외부 실행 경로에서 같은 진입점을 재사용한다.
        let requestedMemoCount = CommandLine.arguments.filter { $0 == "--new-memo" }.count
        for _ in 0..<requestedMemoCount {
            container.windowRegistry.createMemo()
        }

        // 슬래시 팝업이 실제로 뜨는지 확인하기 위한 경로.
        // 팝업은 창 상태에 좌우돼 단위 테스트로는 잡히지 않는 문제가 있어,
        // 실행한 앱에서 직접 재현할 수 있게 열어 둔다.
        // `--demo-command=제목` 처럼 주면 그 명령을 치고 엔터까지 눌러 본다.
        // 창 상태·그리기와 얽힌 문제는 실행 중인 앱에서만 드러나기 때문이다.
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-command=") }) {
            let keyword = String(argument.dropFirst("--demo-command=".count))
            container.windowRegistry.insertTextInFrontmostMemo("/" + keyword)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak container] in
                container?.windowRegistry.simulateReturnKeyInFrontmostMemo()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    FileHandle.standardError.write(Data("엔터 처리 후에도 앱이 살아 있음\n".utf8))
                }
            }
        }

        if CommandLine.arguments.contains("--demo-slash") {
            container.windowRegistry.insertTextInFrontmostMemo("/")
            // 배치가 끝난 뒤의 실제 치수를 찍는다. 계산과 화면이 어긋나는지 눈으로 확인할 수 있다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak container] in
                let report = (container?.windowRegistry.slashPopupDiagnostics ?? "확인 불가") + "\n"
                FileHandle.standardError.write(Data(report.utf8))
            }
        }
    }

    /// 창을 모두 닫아도 메뉴바에 남아 있어야 한다 (ALM-06, SYS-01).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 종료 직전에 편집 중이던 내용을 확실히 기록한다. 디바운스를 기다리지 않는다 (DAT-03).
    func applicationWillTerminate(_ notification: Notification) {
        container?.windowRegistry.flushAllBeforeTermination()
    }
}
