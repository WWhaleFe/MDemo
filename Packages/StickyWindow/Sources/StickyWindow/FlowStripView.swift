import AppKit
import MemoCore

/// 메모 창 아래에서 흐름의 위치와 이어진 메모를 보여 준다.
@MainActor
final class FlowStripView: NSView {
    var previous: MemoID?
    var next: MemoID?
    var onOpen: ((MemoID) -> Void)?
    var topInset: CGFloat = 40
    private var relations = MemoStripRelations.calculate(current: MemoID(rawValue: ""), flow: nil, edges: [], depth: 1)
    private var settings = MemoStripSettings()
    private var current: MemoID?
    private var summaries: [MemoID: MemoSummary] = [:]
    private let expandButton = StripChevronButton()
    private var panel: RelationPanelView?
    private var escapeMonitor: Any?
    private var closeTask: DispatchWorkItem?
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
        expandButton.target = self
        expandButton.action = #selector(toggleExpanded)
        expandButton.toolTip = "이어진 메모 펼치기"
        expandButton.isBordered = false
        addSubview(expandButton)
        previousButton.action = #selector(openPrevious)
        nextButton.action = #selector(openNext)
        previousButton.toolTip = "흐름의 이전 메모 열기"
        nextButton.toolTip = "흐름의 다음 메모 열기"
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("스토리보드를 사용하지 않는다") }

    func update(relations: MemoStripRelations, settings: MemoStripSettings, current: MemoID, summaries: [MemoID: MemoSummary]) {
        if self.current != current || self.relations != relations || self.settings != settings || self.summaries != summaries { collapse() }
        self.current = current
        self.relations = relations
        self.settings = settings
        self.summaries = summaries
        let flow = relations.flow
        let ids = flow?.memoIDs ?? []
        index = ids.firstIndex(of: current) ?? 0
        count = ids.count
        previous = index > 0 ? ids[index - 1] : nil
        next = index + 1 < count ? ids[index + 1] : nil
        previousTitle = previous.flatMap { summaries[$0]?.title } ?? ""
        nextTitle = next.flatMap { summaries[$0]?.title } ?? ""
        flowTitle = ids.first.flatMap { summaries[$0]?.title } ?? ""
        if flow == nil {
            var seen = Set<MemoID>()
            let ids = relations.direct.map(\.other).filter { seen.insert($0).inserted }
            previous = ids.first
            next = ids.dropFirst().first
            previousTitle = previous.flatMap { summaries[$0]?.title } ?? ""
            nextTitle = next.flatMap { summaries[$0]?.title } ?? ""
        }
        needsLayout = true
        needsDisplay = true
    }
    @objc private func openPrevious() { if let previous { open(previous) } }
    @objc private func openNext() { if let next { open(next) } }

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
        expandButton.frame = NSRect(x: 6, y: 6, width: 24, height: 24)
        expandButton.contentTintColor = dark ? .white : ink
        let width: CGFloat = bounds.width < 240 ? 28 : min(106, bounds.width * 0.22)
        previousButton.frame = NSRect(x: 36, y: 5, width: width, height: 26)
        layoutPanel()
        // 오른쪽 아래 크기 조절 손잡이와 겹치지 않게 조금 더 띄운다.
        let reserve: CGFloat = count == 0 && Set(relations.direct.map(\.other)).count > 2 ? 22 : 0
        nextButton.frame = NSRect(x: bounds.width - width - 18 - reserve, y: 5, width: width, height: 26)
        if count == 0 { previousButton.frame.origin.x = next == nil ? nextButton.frame.minX : nextButton.frame.minX - width - 6 }
        // 테두리 없는 버튼은 안쪽 여백이 없다. 양옆 12pt를 남기도록 제목을 직접 줄여 테두리에 붙지 않게 한다.
        let font = previousButton.font ?? NSFont.systemFont(ofSize: 12)
        previousButton.title = bounds.width < 240 ? "‹" : (count == 0 ? "" : "‹ ") + Self.fitted(previousTitle, width: width - 24, font: font)
        nextButton.title = bounds.width < 240 ? "›" : Self.fitted(nextTitle, width: width - 24, font: font) + (count == 0 ? "" : " ›")
        previousButton.toolTip = count == 0 ? previousTitle : "흐름의 이전 메모 열기"
        nextButton.toolTip = count == 0 ? nextTitle : "흐름의 다음 메모 열기"
        previousButton.isHidden = previous == nil || (count == 0 && bounds.width < 240)
        nextButton.isHidden = next == nil || (count == 0 && bounds.width < 240)
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
        let extra = settings.showRelations ? relations.direct.filter { $0.kind != .flow }.count : 0
        if count == 0 {
            drawRelationSummary(color: color)
            return
        }
        let number = ("\(index + 1)/\(count)" + (extra > 0 ? " +\(extra)" : "")) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: color]
        let numberWidth = number.size(withAttributes: attributes).width
        number.draw(at: NSPoint(x: end - numberWidth, y: 10), withAttributes: attributes)
        if bounds.width >= 240 {
            color.setStroke()
            let symbol = NSBezierPath()
            symbol.move(to: NSPoint(x: start + 4, y: 18)); symbol.line(to: NSPoint(x: start + 14, y: 18))
            symbol.lineWidth = 1.5; symbol.stroke()
            for x in [start, start + 12] {
                let circle = NSBezierPath(ovalIn: NSRect(x: x, y: 15, width: 6, height: 6))
                circle.lineWidth = 1.5; circle.stroke()
            }
        }
        let dotsWidth: CGFloat = count <= 7 && bounds.width >= 240 ? CGFloat(count) * 12 + 4 : 0
        let titleWidth = max(0, end - numberWidth - dotsWidth - start - 26)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        ((bounds.width < 240 ? "" : flowTitle) as NSString).draw(in: NSRect(x: start + 24, y: 10, width: titleWidth, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color, .paragraphStyle: paragraph])
        if count <= 7 && bounds.width >= 240 {
            for offset in 0..<count {
                let active = offset == index
                let size: CGFloat = active ? 10 : 8
                let dot = NSBezierPath(ovalIn: NSRect(x: end - numberWidth - dotsWidth + CGFloat(offset) * 12, y: 18 - size / 2, width: size, height: size))
                (active ? NSColor(srgbRed: 212/255, green: 245/255, blue: 60/255, alpha: 1) : ink.withAlphaComponent(0.22)).setFill(); dot.fill()
                if active { ink.setStroke(); dot.lineWidth = 1.5; dot.stroke() }
            }
        }
    }
    private func drawRelationSummary(color: NSColor) {
        let counts = Dictionary(grouping: relations.direct, by: \.kind).mapValues(\.count)
        let kinds = MemoLinkKind.allCases.filter { counts[$0] != nil }
        let summary = bounds.width < 240 ? "\(relations.direct.count)" : kinds.map { "\($0.displayName) \(counts[$0]!)" }.joined(separator: " · ")
        if let kind = kinds.max(by: { counts[$0, default: 0] < counts[$1, default: 0] }), bounds.width >= 240 {
            RelationLine.draw(kind: kind, from: NSPoint(x: 36, y: 18), to: NSPoint(x: 58, y: 18), color: color)
        }
        let x: CGFloat = bounds.width < 240 ? 36 : 64
        (summary as NSString).draw(in: NSRect(x: x, y: 10, width: max(0, (bounds.width < 240 ? bounds.width - 18 : previousButton.frame.minX - 6) - x), height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color])
        let remaining = Set(relations.direct.map(\.other)).count - 2
        if remaining > 0 && bounds.width >= 240 {
            ("+\(remaining)" as NSString).draw(at: NSPoint(x: bounds.width - 22, y: 10), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: color])
        }
    }

    func open(_ id: MemoID) { collapse(); onOpen?(id) }
    @objc private func toggleExpanded() {
        if panel != nil { collapse(); return }
        guard let host = superview, let current else { return }
        let view = RelationPanelView(relations: relations, current: current, summaries: summaries, map: settings.expandedStyle == "map")
        view.onOpen = { [weak self] in self?.open($0) }
        view.onHover = { [weak self] inside in self?.hover(inside) }
        panel = view
        host.addSubview(view, positioned: .above, relativeTo: nil)
        expandButton.setExpanded(true)
        layoutPanel()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil, event.window === self.window, event.keyCode == 53 else { return event }
            self.collapse()
            return nil
        }
    }
    func collapse() {
        closeTask?.cancel(); closeTask = nil
        panel?.removeFromSuperview(); panel = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        expandButton.setExpanded(false)
    }
    func layoutPanel() {
        guard let panel, let host = superview else { return }
        panel.configure(width: bounds.width)
        let height = min(panel.contentHeight, max(0, host.bounds.height - topInset - 36 - 8))
        let strip = convert(bounds, to: host)
        panel.frame = NSRect(x: strip.minX, y: host.isFlipped ? strip.minY - height : strip.maxY, width: bounds.width, height: height)
        panel.needsLayout = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
    private func hover(_ inside: Bool) {
        closeTask?.cancel()
        guard !inside, panel != nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            let point = window.mouseLocationOutsideOfEventStream
            if self.bounds.contains(self.convert(point, from: nil)) || self.panel.map({ $0.bounds.contains($0.convert(point, from: nil)) }) == true { return }
            self.collapse()
        }
        closeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { collapse() }
        super.viewWillMove(toWindow: newWindow)
    }

}
