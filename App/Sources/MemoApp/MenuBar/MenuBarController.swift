import AppKit
import Services
import StickyWindow

/// 메뉴바 아이콘과 메뉴 (SYS-01, SYS-02).
///
/// 아직 구현되지 않은 항목은 숨기지 않고 비활성 상태로 두어,
/// 지금 어디까지 만들어졌는지 앱에서 바로 확인할 수 있게 한다.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let windowRegistry: WindowRegistry
    private let memoryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(windowRegistry: WindowRegistry) {
        self.windowRegistry = windowRegistry
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "note.text",
            accessibilityDescription: "메모"
        )
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(item(title: "새 메모", action: #selector(newMemo), key: "n"))
        menu.addItem(.separator())

        menu.addItem(item(title: "모든 메모 숨기기", action: #selector(hideAllMemos), key: ""))
        menu.addItem(item(title: "모든 메모 보이기", action: #selector(showAllMemos), key: ""))
        menu.addItem(item(title: "모든 메모 창 닫기", action: #selector(closeAllMemos), key: ""))
        menu.addItem(.separator())

        menu.addItem(disabledItem(title: "메모 목록…  (M3)"))
        menu.addItem(disabledItem(title: "iCloud에 저장 / 불러오기  (M4)"))
        menu.addItem(disabledItem(title: "환경설정…  (M3)"))
        menu.addItem(.separator())

        // 메모리 최소화가 제1 요구사항이므로 사용량을 항상 확인할 수 있게 노출한다 (§4-5).
        memoryItem.isEnabled = false
        menu.addItem(memoryItem)
        menu.addItem(.separator())

        menu.addItem(item(title: "종료", action: #selector(quit), key: "q"))
        return menu
    }

    private func item(title: String, action: Selector, key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    private func disabledItem(title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    /// 메뉴를 열 때마다 현재 상태를 갱신한다.
    func menuWillOpen(_ menu: NSMenu) {
        memoryItem.title = "메모리 \(MemoryReporter.formattedFootprint())  ·  열린 메모 \(windowRegistry.openCount)개"
    }

    @objc private func newMemo() {
        windowRegistry.createMemo()
    }

    @objc private func hideAllMemos() {
        windowRegistry.setAllHidden(true)
    }

    @objc private func showAllMemos() {
        windowRegistry.setAllHidden(false)
    }

    @objc private func closeAllMemos() {
        windowRegistry.closeAll()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
