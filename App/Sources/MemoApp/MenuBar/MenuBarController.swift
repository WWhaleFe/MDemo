import AppKit
import EditorKit
import Features
import MarkdownEngine
import MemoCore
import Services
import StickyWindow
import UniformTypeIdentifiers

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
    private let listWindow: MemoListWindowController

    private let memoryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var hoverOpaqueItem: NSMenuItem?
    private let syncStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var autoSyncItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private let syncCoordinator: SyncCoordinator
    private let fontMenu = NSMenu()
    private let fontSizeMenu = NSMenu()
    private let memoSizeMenu = NSMenu()

    init(
        windowRegistry: WindowRegistry,
        store: MemoStore,
        preferences: AppPreferences,
        listWindow: MemoListWindowController,
        syncCoordinator: SyncCoordinator
    ) {
        self.syncCoordinator = syncCoordinator
        self.windowRegistry = windowRegistry
        self.store = store
        self.preferences = preferences
        self.listWindow = listWindow
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

        menu.addItem(item(title: "새 메모  (어디서든 ⌘⇧N)", action: #selector(newMemo), key: "n"))
        menu.addItem(.separator())

        menu.addItem(item(title: "모든 메모 보이기/숨기기  (어디서든 ⌘⇧H)", action: #selector(toggleAllMemos), key: ""))
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

        let loginItem = item(title: "로그인할 때 자동 실행", action: #selector(toggleLaunchAtLogin), key: "")
        loginItem.toolTip = "메뉴바에 늘 떠 있게 합니다"
        launchAtLoginItem = loginItem
        menu.addItem(loginItem)

        let hoverItem = item(title: "마우스 올리면 또렷하게", action: #selector(toggleHoverOpaque), key: "")
        hoverItem.toolTip = "투명하게 둔 메모를 읽을 때만 또렷해집니다"
        hoverOpaqueItem = hoverItem
        menu.addItem(hoverItem)

        let helpItem = NSMenuItem(title: "서식 넣는 법", action: nil, keyEquivalent: "")
        helpItem.submenu = buildFormattingHelpMenu()
        menu.addItem(helpItem)
        menu.addItem(.separator())

        menu.addItem(item(title: "메모 목록…", action: #selector(showList), key: "l"))

        let backupItem = NSMenuItem(title: "백업", action: nil, keyEquivalent: "")
        backupItem.submenu = buildBackupMenu()
        menu.addItem(backupItem)
        let syncItem = NSMenuItem(title: "iCloud 동기화", action: nil, keyEquivalent: "")
        syncItem.submenu = buildSyncMenu()
        menu.addItem(syncItem)
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

    // MARK: - 백업과 가져오기 (DAT-04, DAT-05, DAT-07)

    private func buildBackupMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(title: "전체 백업 내보내기…", action: #selector(exportBackup), key: ""))
        menu.addItem(item(title: "백업에서 복원…", action: #selector(importBackup), key: ""))
        menu.addItem(.separator())
        menu.addItem(item(title: "파일에서 메모 가져오기…", action: #selector(importFiles), key: ""))
        return menu
    }

    private var backupService: BackupService {
        BackupService(dataRoot: FileMemoRepository.defaultRootDirectory())
    }

    @objc private func exportBackup() {
        let panel = NSSavePanel()
        panel.title = "전체 백업 내보내기"
        panel.nameFieldStringValue = "MemoApp-백업-\(Self.todayText()).zip"
        panel.allowedContentTypes = [.zip]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try backupService.exportBackup(to: url)
            showInfo("백업을 저장했습니다", detail: url.lastPathComponent)
        } catch {
            showError("백업에 실패했습니다", error: error)
        }
    }

    @objc private func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "백업에서 복원"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 되돌릴 수 없는 선택이므로 무엇이 일어나는지 분명히 묻는다.
        let alert = NSAlert()
        alert.messageText = "어떻게 복원할까요?"
        alert.informativeText = "지금 있는 메모를 그대로 두고 백업 내용을 더하거나, 백업 상태로 통째로 되돌릴 수 있습니다."
        alert.addButton(withTitle: "합치기")
        alert.addButton(withTitle: "통째로 교체")
        alert.addButton(withTitle: "취소")

        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }
        let replace = (choice == .alertSecondButtonReturn)

        do {
            try backupService.importBackup(from: url, replaceExisting: replace)
            store.reloadSummaries()
            store.reloadGroups()
            windowRegistry.reconcileOpenWindows(with: store)
            listWindow.refreshIfOpen()
            showInfo("복원했습니다", detail: "메모 \(store.summaries.count)개")
        } catch {
            showError("복원에 실패했습니다", error: error)
        }
    }

    @objc private func importFiles() {
        let panel = NSOpenPanel()
        panel.title = "메모로 가져올 파일 고르기"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        var imported = 0
        for url in panel.urls {
            guard let document = try? backupService.makeDocument(fromImportedFile: url) else { continue }
            store.importDocument(document)
            imported += 1
        }
        listWindow.refreshIfOpen()
        showInfo("가져왔습니다", detail: "메모 \(imported)개")
    }

    private static func todayText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func showInfo(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private func showError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - iCloud 동기화 (SYNC-02~05, SYNC-09)

    private func buildSyncMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(item(title: "지금 iCloud에 저장", action: #selector(pushNow), key: ""))
        menu.addItem(item(title: "iCloud에서 불러오기", action: #selector(pullNow), key: ""))
        menu.addItem(.separator())

        let auto = item(title: "자동으로 맞추기 (5분마다)", action: #selector(toggleAutoSync), key: "")
        auto.toolTip = "앱을 켤 때와 5분마다, 끌 때 자동으로 주고받습니다"
        autoSyncItem = auto
        menu.addItem(auto)
        menu.addItem(.separator())

        syncStatusItem.isEnabled = false
        menu.addItem(syncStatusItem)
        return menu
    }

    private func refreshSyncMenuState() {
        autoSyncItem?.state = preferences.autoSyncEnabled ? .on : .off
        if syncCoordinator.isAvailable {
            syncStatusItem.title = syncCoordinator.status.menuText
        } else {
            syncStatusItem.title = "iCloud Drive가 꺼져 있습니다"
            autoSyncItem?.isEnabled = false
        }
    }

    @objc private func pushNow() {
        syncCoordinator.run(mode: .push)
    }

    @objc private func pullNow() {
        syncCoordinator.run(mode: .pull)
    }

    @objc private func toggleAutoSync() {
        preferences.autoSyncEnabled.toggle()
        if preferences.autoSyncEnabled {
            syncCoordinator.start()
        } else {
            syncCoordinator.stopTimer()
        }
    }

    // MARK: - 서식 도움말
    //
    // 슬래시 명령이 있다는 걸 알아도 무엇이 있는지는 열어 봐야 안다.
    // 메뉴에 목록을 그대로 펼쳐 두면 언제든 확인할 수 있다.

    private func buildFormattingHelpMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(sectionHeader("메모에서 / 를 입력하면 아래 목록이 열립니다"))
        for command in SlashCommandCatalog.standard {
            let shortcut = command.shortcut.isEmpty ? "" : "   \(command.shortcut)"
            menu.addItem(disabledItem(title: "/\(command.title)\(shortcut)"))
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("글자 서식은 기호로 감쌉니다"))
        for hint in SlashCommandCatalog.inlineHints {
            menu.addItem(disabledItem(title: "\(hint.label)   \(hint.shortcut)"))
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("목록에서"))
        menu.addItem(disabledItem(title: "엔터   다음 항목 이어가기"))
        menu.addItem(disabledItem(title: "빈 항목에서 엔터   목록 빠져나오기"))
        menu.addItem(disabledItem(title: "Tab / Shift+Tab   단계 내리기 / 올리기"))
        menu.addItem(disabledItem(title: "체크박스 클릭   체크 토글"))
        return menu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
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
        fontSizeMenu.addItem(.separator())

        let auto = item(title: "이 화면에 맞추기", action: #selector(applyDisplayRecommendation), key: "")
        auto.toolTip = "화면 밀도를 재서 글자 크기와 새 메모 크기를 다시 정합니다"
        fontSizeMenu.addItem(auto)
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
            ("작게 (320 × 360)", 320, 360),
            ("보통 (420 × 480)", 420, 480),
            ("크게 (520 × 620)", 520, 620),
            ("길게 (420 × 760)", 420, 760),
            ("넓게 (680 × 480)", 680, 480),
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
        hoverOpaqueItem?.state = preferences.hoverOpaque ? .on : .off
        refreshSyncMenuState()
        launchAtLoginItem?.state = LaunchAtLoginService.isEnabled ? .on : .off
        if LaunchAtLoginService.isBlockedBySystemSettings {
            launchAtLoginItem?.title = "로그인할 때 자동 실행  (시스템 설정에서 허용 필요)"
        }
    }

    @objc private func toggleLaunchAtLogin() {
        if case .failure(let error) = LaunchAtLoginService.setEnabled(!LaunchAtLoginService.isEnabled) {
            let alert = NSAlert()
            alert.messageText = "자동 실행을 설정하지 못했습니다"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func toggleHoverOpaque() {
        preferences.hoverOpaque.toggle()
        windowRegistry.applyPreferencesToOpenWindows()
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
        listWindow.refreshIfOpen()
    }

    @objc private func showList() {
        listWindow.show()
    }

    @objc private func toggleAllMemos() {
        windowRegistry.toggleAllHidden()
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
        preferences.setFontSize(Double(size))
        windowRegistry.applyPreferencesToOpenWindows()
    }

    /// 지금 이 화면의 밀도에 맞춰 글자·창 크기를 다시 정한다.
    /// 모니터를 바꾸거나 화면 해상도를 바꿨을 때 쓴다.
    @objc private func applyDisplayRecommendation() {
        let recommendation = DisplayMetrics.recommended()
        preferences.applyRecommended(
            fontSize: Double(recommendation.fontSize),
            memoWidth: Double(recommendation.memoSize.width),
            memoHeight: Double(recommendation.memoSize.height),
            force: true
        )
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
