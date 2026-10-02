import AppKit

/// 메뉴 안의 누를 수 없는 줄(안내·묶음 제목·상태)을 그리는 뷰.
///
/// 누를 수 없는 메뉴 항목은 시스템이 흐린 회색으로 덮어 그린다. 글자색을 직접 정해도
/// 무시되는 경우가 있어, 반투명한 메뉴 배경 위에서 거의 읽히지 않았다.
/// 항목 대신 글자 칸을 직접 넣으면 색을 시스템이 바꾸지 않고, 마우스를 올려도 반응하지 않는다.
final class MenuInfoView: NSView {
    /// 메뉴 항목 글자가 시작하는 자리와 맞춘다 (체크 표시 칸 다음).
    private static let leadingInset: CGFloat = 14
    private static let trailingInset: CGFloat = 14

    private let label = NSTextField(labelWithString: "")
    private let rowHeight: CGFloat

    init(_ text: NSAttributedString, rowHeight: CGFloat = 22) {
        self.rowHeight = rowHeight
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = true
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        addSubview(label)
        // 메뉴 폭은 가장 넓은 항목을 따른다. 그 폭에 맞춰 늘어나게 둔다.
        autoresizingMask = [.width]
        setText(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("스토리보드를 사용하지 않는다")
    }

    /// 글자를 바꾸고 그 길이에 맞게 줄 폭을 다시 잡는다. 상태 줄처럼 메뉴를 열 때마다 바뀌는 곳에 쓴다.
    func setText(_ text: NSAttributedString) {
        label.attributedStringValue = text
        let size = label.fittingSize
        frame.size = NSSize(
            width: Self.leadingInset + ceil(size.width) + Self.trailingInset,
            height: rowHeight
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = ceil(label.fittingSize.height)
        label.frame = NSRect(
            x: Self.leadingInset,
            y: (bounds.height - height) / 2,
            width: max(0, bounds.width - Self.leadingInset - Self.trailingInset),
            height: height
        )
    }
}

@MainActor
extension NSMenuItem {
    /// 글자 칸을 넣은 누를 수 없는 줄.
    static func info(_ text: NSAttributedString, rowHeight: CGFloat = 22) -> NSMenuItem {
        let item = NSMenuItem(title: text.string, action: nil, keyEquivalent: "")
        item.view = MenuInfoView(text, rowHeight: rowHeight)
        return item
    }

    /// 글자 칸을 넣은 줄의 글자를 바꾼다.
    func setInfoText(_ text: NSAttributedString) {
        title = text.string
        (view as? MenuInfoView)?.setText(text)
    }
}
