import AppKit
import EditorKit
import MarkdownEngine
import Services

/// 메모 창에 붙는 서식 막대 (FMT-01).
///
/// 서식을 넣는 길은 이미 셋 있다 — 마크다운 기호, 슬래시 명령, 단축키.
/// 셋 다 "무엇이 있는지 알고 있을 때" 빠른 길이라, 처음 쓰는 사람에게는 아무것도 없는 것과 같다.
/// 눈에 보이는 버튼을 두면 그 벽이 사라진다.
///
/// 두 묶음으로 나눈 기준은 문단이냐 글자냐다.
/// 첫 묶음은 줄 전체를 바꾸는 것(제목·목록·인용·코드 박스),
/// 둘째 묶음은 고른 글자를 바꾸는 것(굵게·색·형광)과 자리 조정이다.
/// 위아래에 붙으면 두 줄로, 좌우에 붙으면 두 칸으로 선다 (FMT-04).
public final class FormatToolbarView: NSView {
    /// 버튼을 눌렀을 때 벌어질 일. 실제 적용은 편집기 쪽이 한다.
    public enum Command: Equatable {
        case block(BlockStyle)
        case inline(InlineStyleTag)
        case indent(deeper: Bool)
        case fontStep(delta: Int)
        /// 글자 색. nil이면 기본색으로 되돌린다.
        case textColor(String?)
        /// 형광펜 칠. nil이면 기본 노랑.
        case highlightColor(String?)
        case removeHighlight
    }

    /// 누르면 바로 적용하지 않고 색 고르기 메뉴를 여는 버튼.
    private enum ColorMenu {
        case text
        case highlight
    }

    public var onCommand: ((Command) -> Void)?

    /// 버튼 위에 마우스가 올라왔을 때. 이름표를 띄우는 일은 창 쪽이 한다 (FMT-05).
    ///
    /// 시스템 툴팁(`toolTip`)은 앱이 활성 상태일 때만 뜬다.
    /// 이 앱은 메뉴바 앱이고 메모 창은 대개 비활성이라, 그 길로는 이름이 끝내 보이지 않는다.
    public var onHoverItem: ((_ text: String?, _ buttonFrame: NSRect) -> Void)?

    /// 막대가 붙은 자리. 본문과 맞닿은 쪽에 실선을 긋고, 버튼을 줄로 세울지 칸으로 세울지 정한다.
    public var position: FormatToolbarPosition = .top {
        didSet {
            guard position != oldValue else { return }
            if position.isVertical != oldValue.isVertical {
                rebuild()
            }
            needsDisplay = true
        }
    }

    /// 버튼 크기의 기준. 본문 글자 크기와 따로 고정해 둔다.
    private let fontSize: CGFloat
    private var buttons: [NSButton] = []
    private var commands: [Command] = []
    private var helps: [String] = []
    private var menus: [ColorMenu?] = []
    private var layoutConstraints: [NSLayoutConstraint] = []

    /// 버튼 하나의 크기. 글자 크기를 키워 쓰는 사람에게는 버튼도 같이 커져야 누를 수 있다.
    private static func buttonSize(for fontSize: CGFloat) -> CGFloat {
        max(20, min(fontSize * 1.25, 34))
    }

    private static let lineSpacing: CGFloat = 2
    private static let padding: CGFloat = 4

    /// 가로로 누웠을 때의 높이 / 세로로 섰을 때의 너비. 창을 배치하는 쪽에서 미리 알아야 한다.
    public static func thickness(for fontSize: CGFloat) -> CGFloat {
        buttonSize(for: fontSize) * 2 + lineSpacing + padding * 2
    }

    public init(fontSize: CGFloat, position: FormatToolbarPosition = .top) {
        self.fontSize = fontSize
        self.position = position
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("스토리보드를 사용하지 않는다")
    }

    // MARK: - 버튼 목록

    private struct Item {
        /// 그림 기호 이름. nil이면 처음부터 글자로 그린다.
        var symbol: String?
        /// 그림 대신 쓸 글자. 기호가 없거나 그 이름이 시스템에 없을 때 쓴다.
        var fallback: String
        /// 마우스를 올렸을 때 보일 이름.
        var help: String
        var command: Command
        var menu: ColorMenu? = nil
    }

    /// 첫 묶음 — 줄 전체를 바꾸는 서식.
    private static let blockItems: [Item] = [
        Item(symbol: "text.alignleft", fallback: "본문", help: "본문", command: .block(.paragraph)),
        // 제목은 글자로 쓴다. 크기만 다른 그림 기호를 셋 늘어놓으면 어느 것이 몇 단계인지 알 수 없다.
        Item(symbol: nil, fallback: "H1", help: "제목 1  (⌘1)", command: .block(.heading(level: 1))),
        Item(symbol: nil, fallback: "H2", help: "제목 2  (⌘2)", command: .block(.heading(level: 2))),
        Item(symbol: nil, fallback: "H3", help: "제목 3  (⌘3)", command: .block(.heading(level: 3))),
        Item(symbol: "list.bullet", fallback: "•", help: "글머리 목록", command: .block(.bullet(indent: 0))),
        Item(symbol: "list.number", fallback: "1.", help: "번호 목록", command: .block(.ordered(indent: 0, number: 1))),
        Item(symbol: "checklist", fallback: "☐", help: "체크박스  (⌘⇧C)", command: .block(.checkbox(indent: 0, checked: false))),
        Item(symbol: "text.quote", fallback: "❝", help: "인용", command: .block(.quote)),
        // 구분선은 그림 기호(minus)가 너무 가늘어 눈에 걸리지 않는다. 글자로 그린다.
        Item(symbol: nil, fallback: "──", help: "구분선", command: .block(.divider)),
        Item(
            symbol: "chevron.left.forwardslash.chevron.right",
            fallback: "</>",
            help: "코드 박스  (``` 뒤 엔터)",
            command: .block(.codeBlock)
        ),
        Item(symbol: "tablecells", fallback: "▦", help: "표 넣기  (Tab으로 칸 이동)", command: .block(.tableRow)),
    ]

    /// 둘째 묶음 — 고른 글자를 바꾸는 서식과 자리 조정.
    private static let inlineItems: [Item] = [
        Item(symbol: "bold", fallback: "B", help: "굵게  (⌘B)", command: .inline(.bold)),
        Item(symbol: "italic", fallback: "I", help: "기울임  (⌘I)", command: .inline(.italic)),
        Item(symbol: "strikethrough", fallback: "S", help: "취소선  (⌘⇧X)", command: .inline(.strikethrough)),
        Item(symbol: "paintbrush.pointed", fallback: "A", help: "글자 색", command: .textColor(nil), menu: .text),
        Item(symbol: "highlighter", fallback: "H", help: "형광펜 색  (⌘⇧H: 노랑)", command: .highlightColor(nil), menu: .highlight),
        Item(symbol: "curlybraces", fallback: "{}", help: "코드 글자", command: .inline(.code)),
        Item(symbol: "decrease.indent", fallback: "◀", help: "단계 올리기  (⇧Tab)", command: .indent(deeper: false)),
        Item(symbol: "increase.indent", fallback: "▶", help: "단계 내리기  (Tab)", command: .indent(deeper: true)),
        Item(symbol: "textformat.size.smaller", fallback: "A-", help: "글자 작게", command: .fontStep(delta: -1)),
        Item(symbol: "textformat.size.larger", fallback: "A+", help: "글자 크게", command: .fontStep(delta: 1)),
    ]

    // MARK: - 배치

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints = []
        buttons = []
        commands = []
        helps = []
        menus = []

        let lines = [Self.blockItems, Self.inlineItems].map { items -> NSStackView in
            let stack = NSStackView(views: items.map(makeButton))
            stack.orientation = position.isVertical ? .vertical : .horizontal
            stack.alignment = position.isVertical ? .centerX : .centerY
            // 가로로 누우면 창 폭에 맞춰 고르게 벌리고, 세로로 서면 위에서부터 붙여 쌓는다.
            // 세로에서도 벌리면 창이 길 때 버튼이 화면 끝까지 흩어져 한눈에 들어오지 않는다.
            stack.distribution = position.isVertical ? .fill : .equalSpacing
            stack.spacing = position.isVertical ? 4 : 2
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            return stack
        }

        var constraints: [NSLayoutConstraint] = []
        let thickness = Self.buttonSize(for: fontSize)

        for (index, line) in lines.enumerated() {
            let offset = Self.padding + CGFloat(index) * (thickness + Self.lineSpacing)
            if position.isVertical {
                constraints += [
                    line.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                    line.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
                    line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: offset),
                    line.widthAnchor.constraint(equalToConstant: thickness),
                ]
            } else {
                // 양 끝 버튼이 창의 옆 가장자리(크기 조절 자리)에 걸치지 않게 띄운다.
                constraints += [
                    line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ResizeOverlayView.reservedInset),
                    line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ResizeOverlayView.reservedInset),
                    line.topAnchor.constraint(equalTo: topAnchor, constant: offset),
                    line.heightAnchor.constraint(equalToConstant: thickness),
                ]
            }
        }

        layoutConstraints = constraints
        NSLayoutConstraint.activate(constraints)
        invalidateIntrinsicContentSize()
    }

    private func makeButton(for item: Item) -> NSButton {
        let button = ToolbarButton()
        button.title = ""
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityLabel(item.help)
        // 버튼이 입력을 가져가면 글을 쓰던 자리를 잃는다. 커서는 늘 본문에 있어야 한다.
        button.refusesFirstResponder = true
        button.target = self
        button.action = #selector(buttonTapped(_:))
        button.tag = commands.count
        button.onHover = { [weak self, weak button] isInside in
            guard let self, let button else { return }
            onHoverItem?(isInside ? item.help : nil, button.frame)
        }
        commands.append(item.command)
        helps.append(item.help)
        menus.append(item.menu)

        let size = Self.buttonSize(for: fontSize)
        button.translatesAutoresizingMaskIntoConstraints = false
        let width = button.widthAnchor.constraint(equalToConstant: size)
        let height = button.heightAnchor.constraint(equalToConstant: size)
        // 창 크기(우선순위 500)보다 낮게 잡는다.
        // 이보다 높으면 버튼 여러 개의 너비 합이 창의 최소 너비가 되어,
        // 창을 좁히려 할 때 창이 도로 넓어진다. 자리가 모자라면 버튼이 먼저 줄어드는 편이 낫다.
        width.priority = NSLayoutConstraint.Priority(490)
        height.priority = NSLayoutConstraint.Priority(490)
        NSLayoutConstraint.activate([width, height])

        applyImage(item, to: button)
        buttons.append(button)
        return button
    }

    /// 창이 활성 상태가 아니어도 첫 클릭에 바로 반응하는 버튼 (FMT-03).
    ///
    /// 기본 NSButton은 비활성 창에서 첫 클릭을 창을 깨우는 데만 쓴다.
    /// 스티키 노트는 대부분 비활성 상태로 떠 있어서, 그대로 두면 서식마다 두 번씩 눌러야 한다.
    private final class ToolbarButton: NSButton {
        var onHover: ((Bool) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }

    private func applyImage(_ item: Item, to button: NSButton) {
        let glyphSize = Self.buttonSize(for: fontSize) * 0.58
        if let symbol = item.symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.help)?
            .withSymbolConfiguration(.init(pointSize: glyphSize, weight: .regular)) {
            button.image = image
            button.imagePosition = .imageOnly
            // 파스텔 배경 위에서도 또렷하도록 검정 계열로 둔다. 창 색과 무관하게 같은 대비를 준다.
            button.contentTintColor = NSColor.black.withAlphaComponent(0.62)
        } else {
            // 기호 글꼴에 없는 이름이면 글자로 대신한다. 버튼이 빈칸으로 남는 것보다 낫다.
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: item.fallback,
                attributes: [
                    .font: NSFont.systemFont(ofSize: glyphSize * 0.9, weight: .medium),
                    .foregroundColor: NSColor.black.withAlphaComponent(0.62),
                ]
            )
        }
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        guard commands.indices.contains(sender.tag) else { return }
        if let menu = menus[sender.tag] {
            showColorMenu(menu, below: sender)
            return
        }
        onCommand?(commands[sender.tag])
    }

    // MARK: - 색 고르기 메뉴

    /// 색 목록을 버튼 아래에 띄운다. 고른 글자는 메뉴가 떠 있는 동안에도 그대로 선택돼 있다.
    private func showColorMenu(_ kind: ColorMenu, below button: NSButton) {
        onHoverItem?(nil, button.frame)
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch kind {
        case .text:
            menu.addItem(colorItem(title: "기본", swatch: .black, command: .textColor(nil)))
            menu.addItem(.separator())
            for entry in InlineColorPalette.textColors {
                let color = entry.hex.flatMap(InlineColorPalette.color(fromHex:)) ?? .black
                menu.addItem(colorItem(title: entry.name, swatch: color, command: .textColor(entry.hex)))
            }
        case .highlight:
            for entry in InlineColorPalette.highlightColors {
                menu.addItem(colorItem(
                    title: entry.name,
                    swatch: InlineColorPalette.highlightBackground(hex: entry.hex).withAlphaComponent(1),
                    command: .highlightColor(entry.hex)
                ))
            }
            menu.addItem(.separator())
            menu.addItem(colorItem(title: "형광 지우기", swatch: nil, command: .removeHighlight))
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    private func colorItem(title: String, swatch: NSColor?, command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(colorItemChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ColorCommandBox(command)
        item.image = swatch.map(Self.swatchImage)
            ?? NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: title)
        return item
    }

    @objc private func colorItemChosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ColorCommandBox else { return }
        onCommand?(box.command)
    }

    /// 메뉴 항목 앞에 붙는 동그란 색 견본.
    private static func swatchImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        return NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
    }

    /// 메뉴 항목에 명령을 실어 두는 상자. `representedObject`는 객체여야 한다.
    private final class ColorCommandBox: NSObject {
        let command: Command
        init(_ command: Command) { self.command = command }
    }

    /// 버튼 개수. 마우스를 올렸을 때의 동작을 밖에서 확인할 때 쓴다.
    public var buttonCount: Int { buttons.count }

    /// 그 버튼에 마우스를 올린 것과 같은 경로를 태운다.
    /// 이름표는 창 크기와 얽혀 있어(showToolbarHint 참고) 값으로 확인할 수 있어야 한다.
    public func simulateHover(index: Int, isInside: Bool = true) {
        guard buttons.indices.contains(index) else { return }
        onHoverItem?(isInside ? helps[index] : nil, buttons[index].frame)
    }


    public override var intrinsicContentSize: NSSize {
        let thickness = Self.thickness(for: fontSize)
        return position.isVertical
            ? NSSize(width: thickness, height: NSView.noIntrinsicMetric)
            : NSSize(width: NSView.noIntrinsicMetric, height: thickness)
    }

    /// 본문과 맞닿은 쪽에만 실선을 긋는다. 막대와 글이 뒤엉켜 보이지 않게 하는 최소한의 선이다.
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.10).setFill()

        switch position {
        case .top:
            NSRect(x: 6, y: 0, width: bounds.width - 12, height: 1).fill()
        case .bottom:
            NSRect(x: 6, y: bounds.maxY - 1, width: bounds.width - 12, height: 1).fill()
        case .left:
            NSRect(x: bounds.maxX - 1, y: 6, width: 1, height: bounds.height - 12).fill()
        case .right:
            NSRect(x: 0, y: 6, width: 1, height: bounds.height - 12).fill()
        case .hidden:
            break
        }
    }
}
