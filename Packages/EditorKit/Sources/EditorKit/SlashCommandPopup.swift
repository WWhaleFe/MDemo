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

/// 선택된 줄을 뚜렷하게 칠한다.
///
/// 기본 선택 표시는 반투명 배경 위에서 흐릿해 어느 줄이 골라졌는지 알기 어렵다.
/// 강조색으로 채우고 왼쪽에 굵은 띠를 둬서 한눈에 들어오게 한다.
private final class HighlightedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }

        let accent = NSColor.controlAccentColor
        let body = bounds.insetBy(dx: 4, dy: 1)
        NSBezierPath(roundedRect: body, xRadius: 7, yRadius: 7).setClip()
        accent.withAlphaComponent(0.28).setFill()
        body.fill()

        let bar = NSRect(x: body.minX, y: body.minY, width: 3.5, height: body.height)
        accent.setFill()
        bar.fill()
    }

    /// 선택 강조를 직접 그리므로 시스템 기본 강조는 끈다.
    override var isEmphasized: Bool {
        get { true }
        set { }
    }
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
    /// `/` 뒤에 입력한 글자. 목록에서 어느 키워드가 걸렸는지 보여 주는 데 쓴다.
    private var query: String = ""
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

    /// 실제 치수를 그대로 보고한다. 계산과 화면이 어긋날 때 원인을 찾는 데 쓴다.
    var diagnostics: String {
        guard let panel, let table = tableView else { return "팝업이 아직 만들어지지 않음" }
        let clipHeight = table.enclosingScrollView?.contentView.bounds.height ?? 0
        let contentHeight = table.numberOfRows > 0 ? table.rect(ofRow: table.numberOfRows - 1).maxY : 0
        let scrollable = contentHeight > clipHeight + 0.5
        let scroll = table.enclosingScrollView
        let clipWidth = scroll?.contentView.bounds.width ?? 0
        let firstRow = table.numberOfRows > 0 ? table.rect(ofRow: 0) : .zero
        return """
        팝업 창 \(panel.frame.width) × \(panel.frame.height)
        표를 담는 영역 \(clipWidth) × \(clipHeight)
        표 내용 높이 \(contentHeight)  (행 \(table.numberOfRows)개, 행 높이 \(table.rowHeight))
        첫 행 위치 y=\(firstRow.origin.y), x=\(firstRow.origin.x), 너비 \(firstRow.width)
        표 자체 프레임 \(table.frame)
        행간 여백 \(table.intercellSpacing)
        스크롤 발생: \(scrollable ? "예 — \(contentHeight - clipHeight)pt 넘침" : "아니오")
        """
    }

    private static let rowHeight: CGFloat = 42
    /// 목록을 한눈에 보여 주려면 스크롤 없이 전부 보이는 편이 낫다.
    /// 명령이 9개라 이 정도면 대부분 한 화면에 들어온다.
    private static let maximumVisibleRows = 9
    private static let width: CGFloat = 320
    /// 창 테두리와 목록 사이 여백. 위아래·좌우를 같은 값으로 두어 대칭을 맞춘다.
    private static let edgeInset: CGFloat = 4
    private static let horizontalPadding: CGFloat = 4
    /// 행 안쪽 좌우 여백. 왼쪽 제목과 오른쪽 단축키가 같은 간격으로 떨어지게 한다.
    private static let cellInset: CGFloat = 12

    // MARK: - 표시

    func show(commands: [SlashCommand], query: String, below caretRect: NSRect, in window: NSWindow) {
        guard !commands.isEmpty else {
            hide()
            return
        }
        // 이미 떠 있는데 또 창을 앞으로 끌어오면 글자를 칠 때마다 화면이 끊긴다.
        // 처음 뜨는 순간에만 창을 다루고, 그 뒤로는 내용과 크기만 바꾼다.
        let wasVisible = panel?.isVisible ?? false

        self.commands = commands
        self.query = query
        self.selectedIndex = 0

        let panel = ensurePanel()
        parentWindow = window

        // 내용을 먼저 채운 뒤 실제 높이를 재서 창 크기를 정한다.
        // 상수로 어림하면 표가 내부에 넣는 여백만큼 어긋나 스크롤이 생긴다.
        tableView?.reloadData()
        let height = measuredHeight(rowCount: min(commands.count, Self.maximumVisibleRows))

        // 커서 아래에 붙이되, 화면 아래로 넘치면 커서 위로 올린다.
        var origin = NSPoint(x: caretRect.minX, y: caretRect.minY - height - 4)
        if let screen = window.screen, origin.y < screen.visibleFrame.minY {
            origin.y = caretRect.maxY + 4
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        selectRow(0)

        // 자식 창(addChildWindow)으로 붙이지 않는다.
        // 자식 창은 부모와 키 상태를 주고받는데, 그 과정에서 메모 창이 키를 잃으면
        // 키보드 입력이 갈 곳이 없어져 타자도 커서 이동도 죽는다.
        // 레벨만 위로 올려 띄우고, 창이 움직이거나 비활성화되면 직접 정리한다.
        guard !wasVisible else { return }

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

    /// 표가 실제로 차지하는 높이에 창 여백을 더한 값.
    ///
    /// 표는 스타일에 따라 위아래로 여백을 더 넣기도 한다.
    /// 계산으로 어림하지 않고 마지막 행의 아래 끝을 직접 재서 그만큼을 담는다.
    private func measuredHeight(rowCount: Int) -> CGFloat {
        guard let table = tableView, rowCount > 0 else { return Self.rowHeight + Self.edgeInset * 2 }

        let lastRowBottom = table.rect(ofRow: min(rowCount, table.numberOfRows) - 1).maxY
        let contentHeight = max(lastRowBottom, CGFloat(rowCount) * Self.rowHeight)
        return contentHeight + Self.edgeInset * 2
    }

    /// 메모 창이 키 창 자리를 되찾게 한다.
    ///
    /// 첫 응답자만 되돌려서는 부족하다. 키 창이 없으면 키보드 입력 자체가
    /// 어느 창에도 전달되지 않아, 사용자에게는 앱이 멈춘 것처럼 보인다.
    private func restoreFocusToEditor() {
        guard let window = parentWindow else { return }
        // 글자를 조합하는 중에 창을 앞으로 끌어오면 조합이 끊긴다.
        // 이때는 포커스를 건드리지 않는다 — 어차피 입력은 편집기로 흐르고 있다.
        guard !isEditorComposing else { return }

        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        onRestoreFocus?()
    }

    /// 편집기가 글자를 조합 중인지 알려 준다. 컨트롤러가 채워 준다.
    var isEditorComposing: Bool { isComposingProvider?() ?? false }
    var isComposingProvider: (() -> Bool)?

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
        // 기본 행간 여백(세로 2pt)이 행마다 쌓여 마지막 줄을 밀어내고 스크롤을 만든다.
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = []
        // 기본 스타일(.automatic)은 표 위쪽에 10pt를 넣고 좌우로도 넓혀 잡는다.
        // 그 여백이 계산에 없으니 아래가 잘리고 좌우가 어긋났다. 여백 없는 스타일로 고정한다.
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        // 표가 포커스를 가져가면 메모에 타자가 들어가지 않는다.
        table.refusesFirstResponder = true

        // 열 너비를 보이는 영역과 똑같이 맞춘다. 넓으면 오른쪽이 잘려 좌우가 어긋나 보인다.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.width = Self.width - Self.horizontalPadding * 2
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        // 전부 보이는 목록이므로 스크롤로 튕기는 느낌이 없어야 한다.
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(scrollView)
        panel.contentView = background

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.edgeInset),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.edgeInset),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.horizontalPadding),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.horizontalPadding),
        ])

        self.panel = panel
        self.tableView = table
        return panel
    }

    // MARK: - 키보드 조작 (SL-03)

    /// 팝업이 처리한 키면 true. 편집기는 그 키를 무시한다.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        // 이 키는 편집기가 받아서 넘겨준 것이다. 즉 입력은 이미 편집기로 흐르고 있다.
        // 여기서 창의 키 상태를 다시 따지면, 앱이 비활성일 때 정상 입력까지 막혀
        // 엔터를 눌러도 명령이 적용되지 않는다.
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

        // 본문 수정은 다음 차례로 미룬다.
        //
        // 이 함수는 키 입력을 처리하다 불리는데, 그 시점에 AppKit이 화면을 그리는
        // 중일 수 있다. 그리는 도중에 글자를 고치면 예외가 발생하고 앱이 그대로 종료된다.
        // 한글 입력기가 조합을 확정하는 순간과 겹칠 때 특히 잘 나타난다.
        DispatchQueue.main.async { [weak self] in
            self?.onSelect?(command)
        }
    }

    // MARK: - 표 내용

    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HighlightedRowView()
    }

    /// 설명 뒤에 검색 키워드를 붙여 보여 준다.
    ///
    /// 무엇을 쳐야 이 명령이 나오는지 눈으로 익히게 하려는 것이다.
    /// 지금 입력한 글자와 맞는 키워드는 진하게 칠해, 왜 이 항목이 걸렸는지도 함께 보인다.
    private func keywordLine(for command: SlashCommand) -> NSAttributedString {
        let line = NSMutableAttributedString(
            string: command.subtitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )

        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        // 제목과 겹치는 키워드는 빼고, 새로 알 만한 것만 보여 준다.
        let extras = command.keywords.filter { $0.lowercased() != command.title.lowercased() }
        guard !extras.isEmpty else { return line }

        line.append(NSAttributedString(
            string: "   ",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        ))

        for (index, keyword) in extras.enumerated() {
            if index > 0 {
                line.append(NSAttributedString(
                    string: " · ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.quaternaryLabelColor,
                    ]
                ))
            }
            let isMatch = !needle.isEmpty && keyword.lowercased().hasPrefix(needle)
            line.append(NSAttributedString(
                string: keyword,
                attributes: [
                    // 가장 흐린 회색(tertiary)은 반투명 팝업 위에서 거의 읽히지 않는다. 본문 색을 조금만 낮춘다.
                    .font: NSFont.systemFont(ofSize: 11, weight: isMatch ? .semibold : .regular),
                    .foregroundColor: isMatch ? NSColor.controlAccentColor : Self.hintColor,
                ]
            ))
        }
        return line
    }

    /// 보조 글자(검색어·단축키) 색. 제목보다 한 단계 연하지만, 배경 위에서 또렷이 읽히는 정도로 둔다.
    private static let hintColor = NSColor.labelColor.withAlphaComponent(0.72)

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard commands.indices.contains(row) else { return nil }
        let command = commands[row]

        let container = NSView()
        let title = NSTextField(labelWithString: command.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithAttributedString: keywordLine(for: command))
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.lineBreakMode = .byTruncatingTail

        container.addSubview(title)
        container.addSubview(subtitle)
        // 글자 묶음을 세로 가운데에 두고, 좌우 여백을 같은 값으로 맞춘다.
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.cellInset),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -5),
        ])

        // 같은 결과를 내는 마크다운 입력을 오른쪽에 함께 보여 준다.
        // 몇 번 보다 보면 팝업을 열지 않고도 바로 치게 된다.
        if !command.shortcut.isEmpty {
            let shortcut = NSTextField(labelWithString: command.shortcut)
            shortcut.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            shortcut.textColor = Self.hintColor
            shortcut.alignment = .right
            shortcut.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(shortcut)
            NSLayoutConstraint.activate([
                shortcut.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.cellInset),
                shortcut.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
                subtitle.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -8),
            ])
        } else {
            subtitle.trailingAnchor
                .constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -Self.cellInset)
                .isActive = true
        }
        return container
    }
}
