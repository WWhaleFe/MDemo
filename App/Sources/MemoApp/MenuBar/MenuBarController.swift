import AppKit
import EditorKit
import MemoCore
import Services
import StickyWindow

/// 메뉴바 아이콘과 메뉴 (SYS-01, SYS-02).
///
/// 환경설정 창(SET-*)은 M3에서 만든다. 그전까지 자주 바꾸는 항목(글꼴, 글자 크기,
/// 새 메모 기본 크기)은 여기서 바로 조절할 수 있게 해 둔다.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let windowRegistry: WindowRegistry
    private let store: MemoStore
    private let preferences: AppPreferences

    private let memoryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let fontMenu = NSMenu()
    private let fontSizeMenu = NSMenu()
    private let memoSizeMenu = NSMenu()

    init(windowRegistry: WindowRegistry, store: MemoStore, preferences: AppPreferences) {
        self.windowRegistry = windowRegistry
        self.store = store
        self.preferences = preferences
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

        let fontItem = NSMenuItem(title: "글꼴", action: nil, keyEquivalent: "")
        fontItem.submenu = fontMenu
        menu.addItem(fontItem)

        let sizeItem = NSMenuItem(title: "글자 크기", action: nil, keyEquivalent: "")
        sizeItem.submenu = fontSizeMenu
        menu.addItem(sizeItem)

        let memoSizeItem = NSMenuItem(title: "새 메모 기본 크기", action: nil, keyEquivalent: "")
        memoSizeItem.submenu = memoSizeMenu
        menu.addItem(memoSizeItem)
        menu.addItem(.separator())

        menu.addItem(disabledItem(title: "메모 목록…  (M3)"))
        menu.addItem(disabledItem(title: "iCloud에 저장 / 불러오기  (M4)"))
        menu.addItem(.separator())

        // 메모리 최소화가 제1 요구사항이므로 사용량을 항상 확인할 수 있게 노출한다 (§4-5).
        memoryItem.isEnabled = false
        menu.addItem(memoryItem)
        menu.addItem(.separator())

        menu.addItem(item(title: "종료", action: #selector(quit), key: "q"))

        // 글꼴 목록은 설치된 글꼴을 전부 열어 한글 지원 여부를 확인해야 해서 비싸다.
        // 시작할 때 만들지 않고, 사용자가 글꼴 메뉴를 실제로 열 때 한 번만 만든다 (§4-5).
        fontMenu.delegate = self

        buildFontSizeMenu()
        buildMemoSizeMenu()
        return menu
    }

    // MARK: - 글꼴 (TXT-02)

    private func buildFontMenu() {
        fontMenu.removeAllItems()

        let automatic = item(title: "자동 (맑은 고딕 우선)", action: #selector(selectAutomaticFont), key: "")
        automatic.toolTip = "맑은 고딕이 설치돼 있으면 사용하고, 없으면 가장 비슷한 글꼴로 대체합니다"
        fontMenu.addItem(automatic)
        fontMenu.addItem(.separator())

        // 한글이 표시되는 글꼴만 올린다. 전체 목록은 대부분 한글이 깨져 고를 이유가 없다.
        let header = NSMenuItem(title: "한글 글꼴", action: nil, keyEquivalent: "")
        header.isEnabled = false
        fontMenu.addItem(header)

        for family in FontResolver.koreanCapableFamilies {
            let menuItem = item(title: family, action: #selector(selectFont(_:)), key: "")
            menuItem.representedObject = family
            fontMenu.addItem(menuItem)
        }
    }

    private func refreshFontMenuState() {
        let resolved = preferences.fontFamily
        for menuItem in fontMenu.items {
            if menuItem.action == #selector(selectAutomaticFont) {
                menuItem.state = resolved == nil ? .on : .off
            } else if let family = menuItem.representedObject as? String {
                menuItem.state = (family == resolved) ? .on : .off
            }
        }
        if resolved == nil, let fallback = FontResolver.defaultFamily() {
            fontMenu.items.first?.title = "자동 — \(fallback)"
        }
    }

    // MARK: - 글자 크기 (TXT-03)

    private func buildFontSizeMenu() {
        fontSizeMenu.removeAllItems()
        for size in EditorTheme.fontSizeSteps {
            let menuItem = item(title: "\(Int(size)) pt", action: #selector(selectFontSize(_:)), key: "")
            menuItem.representedObject = size
            fontSizeMenu.addItem(menuItem)
        }
    }

    private func refreshFontSizeMenuState() {
        for menuItem in fontSizeMenu.items {
            guard let size = menuItem.representedObject as? CGFloat else { continue }
            menuItem.state = abs(Double(size) - preferences.fontSize) < 0.5 ? .on : .off
        }
    }

    // MARK: - 새 메모 기본 크기 (SET-01)

    private func buildMemoSizeMenu() {
        memoSizeMenu.removeAllItems()

        let presets: [(String, Double, Double)] = [
            ("작게 (260 × 260)", 260, 260),
            ("보통 (320 × 340)", 320, 340),
            ("크게 (400 × 460)", 400, 460),
            ("길게 (320 × 560)", 320, 560),
            ("넓게 (520 × 360)", 520, 360),
        ]
        for (title, width, height) in presets {
            let menuItem = item(title: title, action: #selector(selectMemoSize(_:)), key: "")
            menuItem.representedObject = NSSize(width: width, height: height)
            memoSizeMenu.addItem(menuItem)
        }

        memoSizeMenu.addItem(.separator())
        let adopt = item(title: "현재 창 크기를 기본값으로", action: #selector(adoptCurrentSize), key: "")
        adopt.toolTip = "마음에 드는 크기로 창을 맞춰 두고 이걸 누르면 새 메모가 그 크기로 열립니다"
        memoSizeMenu.addItem(adopt)
    }

    private func refreshMemoSizeMenuState() {
        for menuItem in memoSizeMenu.items {
            guard let size = menuItem.representedObject as? NSSize else { continue }
            let matches = abs(size.width - preferences.defaultMemoWidth) < 1
                && abs(size.height - preferences.defaultMemoHeight) < 1
            menuItem.state = matches ? .on : .off
        }
        memoSizeMenu.items.last?.title =
            "현재 창 크기를 기본값으로  (지금 \(Int(preferences.defaultMemoWidth)) × \(Int(preferences.defaultMemoHeight)))"
    }

    // MARK: - 공통

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
        guard menu !== fontMenu else { return }
        memoryItem.title = "메모리 \(MemoryReporter.formattedFootprint())"
            + "  ·  열린 창 \(windowRegistry.openCount)개"
            + "  ·  전체 \(store.summaries.count)개"
        refreshFontSizeMenuState()
        refreshMemoSizeMenuState()
    }

    /// 글꼴 메뉴를 처음 열 때만 목록을 만든다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === fontMenu else { return }
        if menu.items.isEmpty {
            buildFontMenu()
        }
        refreshFontMenuState()
    }

    // MARK: - 동작

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

    @objc private func selectAutomaticFont() {
        preferences.fontFamily = nil
        windowRegistry.applyPreferencesToOpenWindows()
    }

    @objc private func selectFont(_ sender: NSMenuItem) {
        guard let family = sender.representedObject as? String else { return }
        preferences.fontFamily = family
        windowRegistry.applyPreferencesToOpenWindows()
    }

    @objc private func selectFontSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? CGFloat else { return }
        preferences.fontSize = Double(size)
        windowRegistry.applyPreferencesToOpenWindows()
    }

    @objc private func selectMemoSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? NSSize else { return }
        preferences.setDefaultMemoSize(width: size.width, height: size.height)
    }

    @objc private func adoptCurrentSize() {
        windowRegistry.adoptFrontmostSizeAsDefault()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
