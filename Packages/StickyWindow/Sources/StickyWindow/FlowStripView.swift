import AppKit
import MemoCore

/// 메모 창 아래에서 흐름의 위치와 이웃 메모를 보여 준다.
@MainActor
final class FlowStripView: NSView {
    var previous: MemoID?
    var next: MemoID?
    var onOpen: ((MemoID) -> Void)?
    private var previousTitle = ""
    private var nextTitle = ""
    private var flowTitle = ""
    private var index = 0
    private var count = 0
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private var ink: NSColor { NSColor(srgbRed: 28/255, green: 29/255, blue: 32/255, alpha: 1) }
    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for button in [previousButton, nextButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.lineBreakMode = .byTruncatingTail
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.target = self
            addSubview(button)
        }
        previousButton.action = #selector(openPrevious)
        nextButton.action = #selector(openNext)
        previousButton.toolTip = "흐름의 이전 메모 열기"
        nextButton.toolTip = "흐름의 다음 메모 열기"
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("스토리보드를 사용하지 않는다") }

    func update(flow: MemoFlow?, current: MemoID, summaries: [MemoID: MemoSummary]) {
        let ids = flow?.memoIDs ?? []
        index = ids.firstIndex(of: current) ?? 0
        count = ids.count
        previous = index > 0 ? ids[index - 1] : nil
        next = index + 1 < count ? ids[index + 1] : nil
        previousTitle = previous.flatMap { summaries[$0]?.title } ?? ""
        nextTitle = next.flatMap { summaries[$0]?.title } ?? ""
        flowTitle = ids.first.flatMap { summaries[$0]?.title } ?? ""
        needsLayout = true
        needsDisplay = true
    }
    @objc private func openPrevious() { if let previous { onOpen?(previous) } }
    @objc private func openNext() { if let next { onOpen?(next) } }

    /// 폭에 맞게 끝을 "…"로 줄인다.
    private static func fitted(_ text: String, width: CGFloat, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (text as NSString).size(withAttributes: attributes).width > width else { return text }
        var characters = Array(text)
        while !characters.isEmpty, (String(characters) + "…" as NSString).size(withAttributes: attributes).width > width {
            characters.removeLast()
        }
        return String(characters) + "…"
    }

    override func layout() {
        super.layout()
        let width: CGFloat = bounds.width < 240 ? 28 : min(140, bounds.width * 0.25)
        previousButton.frame = NSRect(x: 6, y: 5, width: width, height: 26)
        // 오른쪽 아래 크기 조절 손잡이와 겹치지 않게 조금 더 띄운다.
        nextButton.frame = NSRect(x: bounds.width - width - 18, y: 5, width: width, height: 26)
        // 테두리 없는 버튼은 안쪽 여백이 없다. 양옆 12pt를 남기도록 제목을 직접 줄여 테두리에 붙지 않게 한다.
        let font = previousButton.font ?? NSFont.systemFont(ofSize: 12)
        previousButton.title = bounds.width < 240 ? "‹" : "‹ " + Self.fitted(previousTitle, width: width - 24 - 12, font: font)
        nextButton.title = bounds.width < 240 ? "›" : Self.fitted(nextTitle, width: width - 24 - 12, font: font) + " ›"
        previousButton.isHidden = previous == nil
        nextButton.isHidden = next == nil
        previousButton.contentTintColor = ink
        nextButton.contentTintColor = dark ? ink : .white
        previousButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        previousButton.layer?.borderColor = ink.withAlphaComponent(0.08).cgColor
        previousButton.layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        nextButton.layer?.backgroundColor = (dark ? NSColor(srgbRed: 237/255, green: 237/255, blue: 239/255, alpha: 1) : ink).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        (dark ? NSColor.black.withAlphaComponent(0.35) : NSColor.white.withAlphaComponent(0.72)).setFill()
        bounds.fill()
        ink.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: bounds.height - 1 / (window?.backingScaleFactor ?? 2), width: bounds.width, height: 1 / (window?.backingScaleFactor ?? 2)).fill()
        let color: NSColor = dark ? .white : ink
        let start = previousButton.frame.maxX + 8
        let end = nextButton.frame.minX - 8
        let number = "\(index + 1)/\(count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: color]
        let numberWidth = number.size(withAttributes: attributes).width
        number.draw(at: NSPoint(x: end - numberWidth, y: 10), withAttributes: attributes)
        color.setStroke()
        let symbol = NSBezierPath()
        symbol.move(to: NSPoint(x: start + 4, y: 18)); symbol.line(to: NSPoint(x: start + 14, y: 18))
        symbol.lineWidth = 1.5; symbol.stroke()
        for x in [start, start + 12] {
            let circle = NSBezierPath(ovalIn: NSRect(x: x, y: 15, width: 6, height: 6))
            circle.lineWidth = 1.5; circle.stroke()
        }
        let dotsWidth: CGFloat = count <= 7 ? CGFloat(count) * 12 + 4 : 0
        let titleWidth = max(0, end - numberWidth - dotsWidth - start - 26)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (flowTitle as NSString).draw(in: NSRect(x: start + 24, y: 10, width: titleWidth, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color, .paragraphStyle: paragraph])
        if count <= 7 {
            for offset in 0..<count {
                let active = offset == index
                let size: CGFloat = active ? 10 : 8
                let dot = NSBezierPath(ovalIn: NSRect(x: end - numberWidth - dotsWidth + CGFloat(offset) * 12, y: 18 - size / 2, width: size, height: size))
                (active ? NSColor(srgbRed: 212/255, green: 245/255, blue: 60/255, alpha: 1) : ink.withAlphaComponent(0.22)).setFill(); dot.fill()
                if active { ink.setStroke(); dot.lineWidth = 1.5; dot.stroke() }
            }
        }
    }
}
