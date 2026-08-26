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

    var isVisible: Bool { panel?.isVisible ?? false }

    private static let rowHeight: CGFloat = 40
    private static let maximumVisibleRows = 6
    private static let width: CGFloat = 260

    // MARK: - 표시

    func show(commands: [SlashCommand], below caretRect: NSRect, in window: NSWindow) {
        guard !commands.isEmpty else {
            hide()
            return
        }
        self.commands = commands
        self.selectedIndex = 0

        let panel = ensurePanel()
        attach(panel, to: window)

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
        panel.orderFront(nil)

        // 팝업이 떠도 입력은 계속 메모 창이 받아야 한다.
        if !window.isKeyWindow {
            window.makeKey()
        }
        onRestoreFocus?()
    }

    /// 팝업을 감춘다. 포커스는 반드시 편집기로 돌려준다.
    func hide() {
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        commands = []
        onRestoreFocus?()
    }

    /// 창이 닫힐 때 팝업 자원을 완전히 버린다 (§4-5).
    func release() {
        hide()
        panel = nil
        tableView = nil
        parentWindow = nil
    }

    private func attach(_ panel: NonFocusingPanel, to window: NSWindow) {
        // 같은 부모에 두 번 붙이면 자식 창이 중복 등록돼 창이 남는다.
        if panel.parent === window { return }
        panel.parent?.removeChildWindow(panel)
        window.addChildWindow(panel, ordered: .above)
        parentWindow = window
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
        panel.hidesOnDeactivate = true
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
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
        ])
        return container
    }
}
