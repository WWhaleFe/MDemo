import AppKit
import MarkdownEngine

/// 절대 입력 포커스를 가져가지 않는 팝업 창.
///
/// 팝업이 키 창이 되면 메모 창이 입력을 잃어 타자가 먹통이 된다.
/// 클릭으로 항목을 고를 때도 포커스는 메모에 남아 있어야 한다.
private final class NonFocusingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 슬래시 명령 팝업 (SL-01 ~ SL-03).
///
/// 메모 창이 항상 위에 뜨는 패널이라, 팝업도 자식 창으로 붙여야 메모 뒤로 숨지 않는다.
@MainActor
final class SlashCommandPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: NonFocusingPanel?
    private var tableView: NSTableView?
    private weak var parentWindow: NSWindow?
    private var commands: [SlashCommand] = []
    private var selectedIndex = 0

    /// 명령을 골랐을 때 호출된다.
    var onSelect: ((SlashCommand) -> Void)?
    /// 팝업이 닫힌 뒤 편집기로 포커스를 되돌리기 위해 호출된다.
    var onRestoreFocus: (() -> Void)?

    /// 팝업이 실제로 쓸 수 있는 상태인가.
    ///
    /// 창은 떠 있는데 목록이 비어 있는 어중간한 상태에서 키를 가로채면
    /// 사용자 입장에서는 키보드가 죽은 것처럼 보인다. 둘 다 만족할 때만 살아 있다고 본다.
    var isVisible: Bool {
        guard let panel, panel.isVisible, !commands.isEmpty else { return false }
        return true
    }

    /// 지금 보이고 있는 명령들.
    var visibleCommands: [SlashCommand] { isVisible ? commands : [] }

    private static let rowHeight: CGFloat = 40
    /// 목록을 한눈에 보여 주려면 스크롤 없이 전부 보이는 편이 낫다.
    /// 명령이 9개라 이 정도면 대부분 한 화면에 들어온다.
    private static let maximumVisibleRows = 9
    private static let width: CGFloat = 320

    // MARK: - 표시

    func show(commands: [SlashCommand], below caretRect: NSRect, in window: NSWindow) {
        guard !commands.isEmpty else {
            hide()
            return
        }
        self.commands = commands
        self.selectedIndex = 0

        let panel = ensurePanel()
        parentWindow = window

        let visibleRows = min(commands.count, Self.maximumVisibleRows)
        let height = CGFloat(visibleRows) * Self.rowHeight + 8
        // 커서 아래에 붙이되, 화면 아래로 넘치면 커서 위로 올린다.
        var origin = NSPoint(x: caretRect.minX, y: caretRect.minY - height - 4)
        if let screen = window.screen, origin.y < screen.visibleFrame.minY {
            origin.y = caretRect.maxY + 4
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: false)

        tableView?.reloadData()
        selectRow(0)

        // 자식 창(addChildWindow)으로 붙이지 않는다.
        // 자식 창은 부모와 키 상태를 주고받는데, 그 과정에서 메모 창이 키를 잃으면
        // 키보드 입력이 갈 곳이 없어져 타자도 커서 이동도 죽는다.
        // 레벨만 위로 올려 띄우고, 창이 움직이거나 비활성화되면 직접 정리한다.
        // 앱이 비활성 상태여도 반드시 보이게 한다. 일반 orderFront는 비활성 앱에서 무시될 수 있다.
        panel.orderFrontRegardless()
        restoreFocusToEditor()
    }

    /// 팝업을 감춘다. 입력 포커스는 반드시 편집기로 돌려준다.
    func hide() {
        commands = []
        guard let panel, panel.isVisible else {
            restoreFocusToEditor()
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        restoreFocusToEditor()
    }

    /// 창이 닫힐 때 팝업 자원을 완전히 버린다 (§4-5).
    func release() {
        hide()
        panel = nil
        tableView = nil
        parentWindow = nil
    }

    /// 메모 창이 키 창 자리를 되찾게 한다.
    ///
    /// 첫 응답자만 되돌려서는 부족하다. 키 창이 없으면 키보드 입력 자체가
    /// 어느 창에도 전달되지 않아, 사용자에게는 앱이 멈춘 것처럼 보인다.
    private func restoreFocusToEditor() {
        guard let window = parentWindow else { return }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        onRestoreFocus?()
    }

    private func ensurePanel() -> NonFocusingPanel {
        if let panel { return panel }

        let panel = NonFocusingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        // 이 앱은 Dock에 없고(LSUIElement) 메모 창도 클릭해도 앱을 활성화하지 않는다.
        // 그래서 앱은 대부분 "비활성" 상태인데, hidesOnDeactivate가 켜져 있으면
        // 팝업이 뜨자마자 숨겨져 사용자에게는 아무것도 나타나지 않는다.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        // 표가 포커스를 가져가면 메모에 타자가 들어가지 않는다.
        table.refusesFirstResponder = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.width = Self.width - 16
        table.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(scrollView)
        panel.contentView = background

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
        ])

        self.panel = panel
        self.tableView = table
        return panel
    }

    // MARK: - 키보드 조작 (SL-03)

    /// 팝업이 처리한 키면 true. 편집기는 그 키를 무시한다.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }

        // 메모 창이 키 창이 아닌데 팝업만 떠 있는 상태라면 무언가 어긋난 것이다.
        // 이때 키를 계속 가로채면 사용자는 입력이 막힌 것으로 느낀다. 정리하고 키를 돌려준다.
        guard parentWindow?.isKeyWindow == true else {
            hide()
            return false
        }

        switch event.keyCode {
        case 126: // ↑
            selectRow(max(0, selectedIndex - 1))
            return true
        case 125: // ↓
            selectRow(min(commands.count - 1, selectedIndex + 1))
            return true
        case 36, 76, 48: // Return, Enter, Tab
            confirmSelection()
            return true
        case 53: // Esc
            hide()
            return true
        default:
            return false
        }
    }

    private func selectRow(_ index: Int) {
        guard commands.indices.contains(index) else { return }
        selectedIndex = index
        tableView?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView?.scrollRowToVisible(index)
    }

    @objc private func rowClicked() {
        guard let row = tableView?.clickedRow, commands.indices.contains(row) else { return }
        selectedIndex = row
        confirmSelection()
    }

    private func confirmSelection() {
        guard commands.indices.contains(selectedIndex) else {
            hide()
            return
        }
        let command = commands[selectedIndex]
        hide()
        onSelect?(command)
    }

    // MARK: - 표 내용

    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard commands.indices.contains(row) else { return nil }
        let command = commands[row]

        let container = NSView()
        let title = NSTextField(labelWithString: command.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: command.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(subtitle)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])

        // 같은 결과를 내는 마크다운 입력을 오른쪽에 함께 보여 준다.
        // 몇 번 보다 보면 팝업을 열지 않고도 바로 치게 된다.
        if !command.shortcut.isEmpty {
            let shortcut = NSTextField(labelWithString: command.shortcut)
            shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            shortcut.textColor = .tertiaryLabelColor
            shortcut.alignment = .right
            shortcut.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(shortcut)
            NSLayoutConstraint.activate([
                shortcut.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                shortcut.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
                subtitle.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -8),
            ])
        } else {
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8).isActive = true
        }
        return container
    }
}
