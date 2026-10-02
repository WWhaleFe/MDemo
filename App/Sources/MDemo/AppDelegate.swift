import AppKit
import Services

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
            preferences: container.preferences,
            listWindow: container.listWindow,
            syncCoordinator: container.syncCoordinator,
            updateChecker: container.updateChecker
        )

        // 새 버전 확인 (켤 때 한 번, 그 뒤 하루에 한 번). 설정에서 끌 수 있다.
        container.updateChecker.startAutomaticChecks()

        // 지난 실행에서 열려 있던 메모를 그대로 되살린다 (WIN-06).
        container.windowRegistry.restoreOpenMemos()

        // 켤 때 한 번 맞추고, 그 뒤로는 주기적으로 (SYNC-05).
        container.syncCoordinator.start()

        registerGlobalHotkeys(container)

        // `open -a MDemo --args --new-memo` 로 실행하면 곧바로 새 메모를 띄운다.
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

        // `--demo-code` 로 실행하면 코드 박스에 예제를 채운 메모를 띄운다.
        // 상자는 레이아웃 매니저가 글자 뒤에 그리는 것이라 자동 테스트로는 확인할 수 없다 (MD-10).
        if CommandLine.arguments.contains("--demo-code") {
            let id = container.windowRegistry.createMemo()
            container.windowRegistry.performToolbarCommand(.block(.codeBlock), in: id)
            container.windowRegistry.insertText("let x = 1", in: id)
            container.windowRegistry.simulateReturnKey(in: id)
            container.windowRegistry.insertText("print(x)  // 상자 안", in: id)
        }

        // `--demo-table` 로 실행하면 표를 넣은 메모를 띄운다. 바탕 띠와 칸 이동을 눈으로 확인한다 (MD-14).
        if CommandLine.arguments.contains("--demo-table") {
            let id = container.windowRegistry.createMemo()
            container.windowRegistry.performToolbarCommand(.block(.tableRow), in: id)
            container.windowRegistry.insertText("월", in: id)
            container.windowRegistry.simulateTabKey(in: id)
            container.windowRegistry.insertText("할 일", in: id)
            container.windowRegistry.simulateTabKey(in: id)
            container.windowRegistry.insertText("9월", in: id)
            container.windowRegistry.simulateTabKey(in: id)
            container.windowRegistry.insertText("메모앱 마무리", in: id)
        }

        if CommandLine.arguments.contains("--show-list") {
            container.listWindow.show()
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

    /// 다른 앱을 쓰는 중에도 손이 기억하는 키로 메모를 띄울 수 있어야 한다 (KEY-11, SYS-04).
    ///
    /// 다른 앱이 이미 쓰고 있는 조합이면 등록에 실패한다. 그때는 조용히 넘어간다 —
    /// 메뉴에 같은 기능이 있으므로 앱을 못 쓰게 되지는 않는다.
    private func registerGlobalHotkeys(_ container: AppContainer) {
        let newMemoRegistered = container.hotkeys.register(.newMemo) { [weak container] in
            container?.windowRegistry.createMemo()
            container?.listWindow.refreshIfOpen()
        }
        let toggleRegistered = container.hotkeys.register(.toggleAllMemos) { [weak container] in
            container?.windowRegistry.toggleAllHidden()
        }

        // 다른 앱이 같은 조합을 쓰고 있으면 등록이 실패한다.
        // 조용히 지나가면 "왜 안 되지"로 이어지므로 확인할 수 있게 찍어 둔다.
        if CommandLine.arguments.contains("--check-hotkeys") {
            let report = """
            새 메모 (\(GlobalHotkeyService.Shortcut.newMemo.displayText)): \(newMemoRegistered ? "등록됨" : "실패 — 다른 앱이 쓰는 중")
            메모 보이기/숨기기 (\(GlobalHotkeyService.Shortcut.toggleAllMemos.displayText)): \(toggleRegistered ? "등록됨" : "실패 — 다른 앱이 쓰는 중")

            """
            FileHandle.standardError.write(Data(report.utf8))
        }
    }

    /// 창을 모두 닫아도 메뉴바에 남아 있어야 한다 (ALM-06, SYS-01).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 종료 직전에 편집 중이던 내용을 확실히 기록한다. 디바운스를 기다리지 않는다 (DAT-03).
    func applicationWillTerminate(_ notification: Notification) {
        container?.windowRegistry.flushAllBeforeTermination()
        // 끄기 직전에 올려 둔다. 다른 기기에서 이어서 쓸 수 있어야 한다 (SYNC-04).
        container?.syncCoordinator.syncBeforeTermination()
    }
}
