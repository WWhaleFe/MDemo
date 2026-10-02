import AppKit

/// 서식 버튼 이름표 (FMT-05).
///
/// NSTextField 하나에 배경을 칠해 쓰면, 높이를 늘렸을 때 글자가 위쪽에 붙고
/// 너비는 글자 폭과 어긋나 한쪽이 비어 보인다. 상자와 글자를 따로 두고,
/// 상자 크기는 글자 크기에 여백만 더해 정한 뒤 글자를 그 한가운데 둔다.
final class ToolbarHintView: NSView {
    /// 글자와 상자 가장자리 사이 여백.
    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 4

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 창 크기에 끼어들지 않도록 오토레이아웃 밖에 둔다 (StickyWindowController.showToolbarHint 참고).
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 5
        isHidden = true

        label.translatesAutoresizingMaskIntoConstraints = true
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        label.isBordered = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("스토리보드를 사용하지 않는다")
    }

    // 이름표가 마우스를 가로채면 그 아래 버튼을 누를 수 없다.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 글자를 바꾸고, 글자에 딱 맞는 상자 크기를 돌려준다. 자리는 부르는 쪽이 정한다.
    func update(text: String, font: NSFont, maxWidth: CGFloat) -> NSSize {
        label.font = font
        label.stringValue = text
        let textSize = label.fittingSize
        let width = min(ceil(textSize.width) + Self.horizontalPadding * 2, maxWidth)
        let height = ceil(textSize.height) + Self.verticalPadding * 2
        return NSSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        // 글자 칸을 상자 한가운데 둔다. 칸 높이는 글자 높이 그대로라 위아래 여백이 같아진다.
        let textHeight = ceil(label.fittingSize.height)
        label.frame = NSRect(
            x: Self.horizontalPadding,
            y: (bounds.height - textHeight) / 2,
            width: max(0, bounds.width - Self.horizontalPadding * 2),
            height: textHeight
        )
    }
}
