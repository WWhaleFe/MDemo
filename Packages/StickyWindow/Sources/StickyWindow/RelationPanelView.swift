import AppKit
import MemoCore

@MainActor
final class StripChevronButton: NSButton {
    override var isFlipped: Bool { false }
    private var expanded = false
    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        needsDisplay = true
    }
    /// 레이어째 돌리면 기준점이 단추 모서리라 꺾쇠가 단추 밖으로 나간다. 가운데를 기준으로 그림만 돌린다.
    override func draw(_ dirtyRect: NSRect) {
        (contentTintColor ?? .labelColor).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: -2, y: -4)); path.line(to: NSPoint(x: 2, y: 0)); path.line(to: NSPoint(x: -2, y: 4))
        var transform = AffineTransform(translationByX: bounds.midX, byY: bounds.midY)
        if expanded { transform.rotate(byDegrees: 90) }
        path.transform(using: transform)
        path.lineWidth = 1.6; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
    }
}

/// 보드의 종류와 방향을 AppKit 선으로 축약해 그린다.
@MainActor
enum RelationLine {
    static func draw(kind: MemoLinkKind, from: NSPoint, to: NSPoint, color: NSColor, thin: Bool = false) {
        color.setStroke(); color.setFill()
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(1, hypot(dx, dy)), ux = dx / length, uy = dy / length
        func point(_ origin: NSPoint, _ along: CGFloat, _ across: CGFloat) -> NSPoint {
            NSPoint(x: origin.x + ux * along - uy * across, y: origin.y + uy * along + ux * across)
        }
        let path = NSBezierPath(); path.move(to: from); path.line(to: to)
        path.lineWidth = thin ? 0.8 : 1.5
        if kind.lineStyle == .dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
        if kind == .oppose {
            let wave = NSBezierPath()
            wave.move(to: from)
            for step in 1...max(1, Int(length / 2)) {
                let d = min(length, CGFloat(step) * length / CGFloat(max(1, Int(length / 2))))
                wave.line(to: point(from, d, 2 * sin(d * .pi / 6)))
            }
            wave.lineWidth = thin ? 0.8 : 1.5; wave.stroke()
        } else { path.stroke() }
        func arrow(_ tip: NSPoint, _ sign: CGFloat) {
            let p = NSBezierPath(); p.move(to: point(tip, -5 * sign, 3)); p.line(to: tip); p.line(to: point(tip, -5 * sign, -3)); p.close(); p.fill()
        }
        if kind.arrows != .none { arrow(to, 1) }
        if kind.arrows == .both { arrow(from, -1) }
        switch kind {
        case .contain:
            NSBezierPath(ovalIn: NSRect(x: from.x - 3, y: from.y - 3, width: 6, height: 6)).fill()
            let fan = NSBezierPath()
            for spread: CGFloat in [-4, 4] { fan.move(to: point(to, -7, 0)); fan.line(to: point(to, 0, spread)) }
            fan.lineWidth = thin ? 0.8 : 1.5; fan.stroke()
        case .block:
            let p = NSBezierPath(); p.move(to: point(to, 0, -5)); p.line(to: point(to, 0, 5)); p.lineWidth = 1.5; p.stroke()
        case .oppose:
            let center = point(from, length / 2, 0)
            NSBezierPath(ovalIn: NSRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)).stroke()
            let p = NSBezierPath(); p.move(to: point(center, -3, -4)); p.line(to: point(center, 3, 4)); p.move(to: point(center, -3, 4)); p.line(to: point(center, 3, -4)); p.stroke()
        case .same:
            let p = NSBezierPath(); p.move(to: point(from, 0, 3)); p.line(to: point(to, 0, 3)); p.stroke()
        default: break
        }
    }
}

@MainActor
private final class RelationCanvas: NSView {
    override var isFlipped: Bool { true }
    var lines: [(MemoLinkKind, NSPoint, NSPoint, Bool)] = []
    var ink = NSColor.labelColor
    override func draw(_ dirtyRect: NSRect) {
        for (kind, from, to, thin) in lines { RelationLine.draw(kind: kind, from: from, to: to, color: ink, thin: thin) }
    }
}

@MainActor
final class RelationPanelView: NSView {
    override var isFlipped: Bool { true }
    var onOpen: ((MemoID) -> Void)?
    var onHover: ((Bool) -> Void)?
    private let relations: MemoStripRelations
    private let current: MemoID
    private let summaries: [MemoID: MemoSummary]
    private let map: Bool
    private let scroll = NSScrollView()
    private let canvas = RelationCanvas()
    private var targets: [NSButton: MemoID] = [:]
    private var lastWidth: CGFloat = -1
    private(set) var contentHeight: CGFloat = 0
    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var ink: NSColor { dark ? .white : NSColor(srgbRed: 28/255, green: 29/255, blue: 32/255, alpha: 1) }
    private let lime = NSColor(srgbRed: 212/255, green: 245/255, blue: 60/255, alpha: 1)

    init(relations: MemoStripRelations, current: MemoID, summaries: [MemoID: MemoSummary], map: Bool) {
        self.relations = relations; self.current = current; self.summaries = summaries; self.map = map
        super.init(frame: .zero)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = canvas; addSubview(scroll)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("스토리보드를 사용하지 않는다") }
    override func layout() { super.layout(); scroll.frame = bounds.insetBy(dx: 0, dy: 0.5) }
    override func draw(_ dirtyRect: NSRect) {
        let base = (superview as? StickyRootView)?.stripBaseColor ?? .white
        let alpha: CGFloat = dark ? 0.35 : 0.72
        let overlay: NSColor = dark ? .black : .white
        (base.blended(withFraction: alpha, of: overlay) ?? base).withAlphaComponent(1).setFill(); bounds.fill()
        ink.withAlphaComponent(0.18).setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); lastWidth = -1; configure(width: bounds.width); needsDisplay = true
    }
    func configure(width: CGFloat) {
        guard width != lastWidth else { return }; lastWidth = width
        canvas.subviews.forEach { $0.removeFromSuperview() }; canvas.lines = []; targets = [:]; canvas.ink = ink
        if map && width >= 240 { buildMap(width: width) } else { buildList(width: width) }
        canvas.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        canvas.needsDisplay = true
    }
    @discardableResult
    private func label(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, small: Bool = false) -> NSTextField {
        let view = NSTextField(labelWithString: title); view.font = .systemFont(ofSize: small ? 10 : 12); view.textColor = ink
        view.lineBreakMode = .byTruncatingTail; view.frame = NSRect(x: x, y: y, width: max(0, width), height: 18); canvas.addSubview(view); return view
    }
    private func chip(_ id: MemoID, title: String? = nil, small: Bool = false, maxWidth: CGFloat) -> NSButton {
        let button = NSButton(title: title ?? summaries[id]?.title ?? "제목 없음", target: self, action: #selector(openChip(_:)))
        button.font = .systemFont(ofSize: small ? 10 : 12); button.isBordered = false; button.lineBreakMode = .byTruncatingTail
        button.wantsLayer = true; button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = (id == current ? lime : NSColor.white.withAlphaComponent(0.72)).cgColor
        button.contentTintColor = NSColor(srgbRed: 28/255, green: 29/255, blue: 32/255, alpha: 1)
        button.toolTip = summaries[id]?.title ?? "이 메모"
        button.setAccessibilityLabel(button.title)
        button.frame.size = NSSize(width: min(maxWidth, max(44, (button.title as NSString).size(withAttributes: [.font: button.font!]).width + 20)), height: small ? 20 : 24)
        if id == current { button.isEnabled = false } else { targets[button] = id }
        canvas.addSubview(button); return button
    }
    @objc private func openChip(_ sender: NSButton) { if let id = targets[sender] { onOpen?(id) } }
    private func buildList(width: CGFloat) {
        let narrow = width < 240
        var y: CGFloat = 10
        func row(kind: MemoLinkKind?, name: String, items: [(MemoID?, String?)], incoming: Bool = false) {
            let start: CGFloat = narrow ? 12 : 96
            if let kind {
                RelationLineSampleView.add(to: canvas, kind: kind, incoming: incoming, ink: ink, frame: NSRect(x: 12, y: y + 4, width: 26, height: 16))
            }
            label(name, x: kind == nil ? 12 : 42, y: y + 5, width: kind == nil ? width - 24 : (narrow ? width - 54 : 54), small: kind == nil)
            var x = start, cy = narrow || kind == nil ? y + 26 : y
            for (id, text) in items {
                let view: NSView
                if let id { view = chip(id, title: text, maxWidth: max(44, min(150, width - start - 14))) }
                else { view = label(text ?? "→", x: 0, y: 0, width: min(width - start - 14, CGFloat((text ?? "→").count) * 12 + 4), small: true) }
                if x + view.frame.width > width - 12 && x > start { x = start; cy += 30 }
                view.frame.origin = NSPoint(x: x, y: cy + (id == nil ? 4 : 0)); x += view.frame.width + 6
            }
            y = cy + 32
        }
        if let flow = relations.flow, let index = flow.memoIDs.firstIndex(of: current) {
            var items: [(MemoID?, String?)] = []
            if index > 0 { items += [(flow.memoIDs[index - 1], nil), (nil, "→")] }
            items.append((current, "이 메모"))
            if index + 1 < flow.memoIDs.count { items += [(nil, "→"), (flow.memoIDs[index + 1], nil)] }
            row(kind: .flow, name: "흐름", items: items)
        }
        for kind in MemoLinkKind.allCases {
            let entries = relations.direct.filter { $0.kind == kind && (kind != .flow || relations.flow == nil) }
            guard !entries.isEmpty else { continue }
            // 방향이 다른 연결은 같은 종류 줄 안에서도 문구와 견본을 구분한다.
            for incoming in [false, true] {
                let group = entries.filter { kind.arrows == .forward || [.contain, .block].contains(kind) ? !$0.outgoing == incoming : !incoming }
                guard !group.isEmpty else { continue }
                var items: [(MemoID?, String?)] = []
                if incoming {
                    let direction = kind == .block ? "이 메모보다 먼저:" : "이 메모를 \(kind.displayName):"
                    items.append((nil, direction))
                }
                items += group.map { ($0.other, nil) }
                row(kind: kind, name: kind.displayName, items: items, incoming: incoming)
            }
        }
        if !relations.indirect.isEmpty {
            var items: [(MemoID?, String?)] = []
            var seen = Set<MemoID>()
            for item in relations.indirect where seen.insert(item.via).inserted {
                items.append((nil, "\(summaries[item.via]?.title ?? "메모") 거쳐"))
                items += relations.indirect.filter { $0.via == item.via }.map { ($0.other, nil) }
            }
            row(kind: nil, name: "건너 이어진 메모", items: items)
        }
        contentHeight = y + 4
    }
    private func buildMap(width: CGFloat) {
        let flowIDs = relations.flow?.memoIDs ?? []
        let index = flowIDs.firstIndex(of: current) ?? 0
        let previous = index > 0 ? flowIDs[index - 1] : nil
        let next = index + 1 < flowIDs.count ? flowIDs[index + 1] : nil
        var seen = Set<MemoID>()
        let others = relations.direct.map(\.other).filter { $0 != current && seen.insert($0).inserted }
        let top = others.filter { $0 != previous && $0 != next }
        let bands = max(1, Int(ceil(Double(top.count) / 4)))
        let outerInset: CGFloat = relations.indirect.isEmpty ? 0 : 60
        let center = NSPoint(x: width / 2, y: CGFloat(bands) * 60 + 60 + outerInset)
        var positions: [MemoID: NSPoint] = [current: center]
        var nodes: [(MemoID, NSPoint, Bool)] = []
        for id in others {
            let p: NSPoint
            if id == previous || id == next {
                p = NSPoint(x: id == next ? width - 55 : 55, y: center.y)
            } else {
                let j = top.firstIndex(of: id) ?? 0
                let column = (j / 2) % 2, band = j / 4
                p = NSPoint(x: width * CGFloat(column + 1) / 3, y: j % 2 == 0 ? 24 + outerInset + CGFloat(band) * 60 : center.y + 76 + CGFloat(band) * 60)
            }
            positions[id] = p; nodes.append((id, p, false))
        }
        for item in relations.direct {
            guard let p = positions[item.other] else { continue }
            let from = item.outgoing ? center : p, to = item.outgoing ? p : center
            canvas.lines.append((item.kind, from, to, false))
            label(item.kind.displayName, x: (from.x + to.x) / 2 - 23, y: (from.y + to.y) / 2 - 16, width: 55, small: true)
        }
        // 흐름 데이터가 가진 이전과 다음은 직접 선이 생략된 경우에도 지도에 남긴다.
        for (offset, x) in [(index - 1, CGFloat(55)), (index + 1, width - 55)] where flowIDs.indices.contains(offset) {
            let id = flowIDs[offset]
            if positions[id] == nil {
                let p = NSPoint(x: x, y: center.y); positions[id] = p; nodes.append((id, p, false))
                canvas.lines.append((.flow, offset < index ? p : center, offset < index ? center : p, false))
            }
        }
        // 두 단계 메모는 거쳐 가는 메모 바로 바깥쪽(가운데에서 멀어지는 방향)에 모은다. 얇은 선에는 이름을 달지 않아 덜 붐비게 한다.
        let groups = Dictionary(grouping: relations.indirect, by: \.via)
        for via in relations.indirect.map(\.via).reduce(into: [MemoID](), { if !$0.contains($1) { $0.append($1) } }) {
            let items = groups[via] ?? []
            let origin = positions[via] ?? center
            var dx = origin.x - center.x, dy = origin.y - center.y
            let length = hypot(dx, dy)
            if length < 1 { dx = 0; dy = -1 } else { dx /= length; dy /= length }
            for (k, item) in items.enumerated() {
                let spread = (CGFloat(k) - CGFloat(items.count - 1) / 2) * 34
                let p = NSPoint(x: min(width - 44, max(44, origin.x + dx * 70 - dy * spread * 2)),
                                y: max(14, origin.y + dy * 52 + dx * spread))
                canvas.lines.append((item.kind, item.outgoing ? origin : p, item.outgoing ? p : origin, true))
                nodes.append((item.other, p, true))
            }
        }
        nodes.append((current, center, false))
        for (id, point, small) in nodes {
            let button = chip(id, title: id == current ? "이 메모" : nil, small: small, maxWidth: small ? min(80, width / 5 - 6) : min(110, width / 3 - 8))
            button.frame.origin = NSPoint(x: point.x - button.frame.width / 2, y: point.y - button.frame.height / 2)
        }
        // 화살촉이 칩 안에 가려지지 않도록 선을 칩 경계에서 끝낸다.
        let frames = canvas.subviews.compactMap { ($0 as? NSButton)?.frame }
        func boundary(_ point: NSPoint, toward other: NSPoint) -> NSPoint {
            guard let frame = frames.first(where: { abs($0.midX - point.x) < 0.5 && abs($0.midY - point.y) < 0.5 }) else { return point }
            let dx = other.x - point.x, dy = other.y - point.y
            let scale = min((frame.width / 2 + 3) / max(0.001, abs(dx)), (frame.height / 2 + 3) / max(0.001, abs(dy)))
            return NSPoint(x: point.x + dx * scale, y: point.y + dy * scale)
        }
        canvas.lines = canvas.lines.map { kind, from, to, thin in
            (kind, boundary(from, toward: to), boundary(to, toward: from), thin)
        }
        contentHeight = max(center.y + CGFloat(bands) * 60 + 40, nodes.map { $0.1.y + 28 }.max() ?? 0)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
private final class RelationLineSampleView: NSView {
    var kind: MemoLinkKind = .line
    var incoming = false
    var ink = NSColor.labelColor
    static func add(to parent: NSView, kind: MemoLinkKind, incoming: Bool, ink: NSColor, frame: NSRect) {
        let view = RelationLineSampleView(frame: frame); view.kind = kind; view.incoming = incoming; view.ink = ink; parent.addSubview(view)
    }
    override func draw(_ dirtyRect: NSRect) {
        let left = NSPoint(x: 2, y: 8), right = NSPoint(x: 24, y: 8)
        RelationLine.draw(kind: kind, from: incoming ? right : left, to: incoming ? left : right, color: ink)
    }
}
