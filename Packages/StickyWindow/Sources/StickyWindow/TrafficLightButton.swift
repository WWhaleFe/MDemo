import AppKit

/// 맥 창의 닫기 버튼 (WIN-02).
///
/// 프레임리스 창이라 시스템 타이틀바가 없고, 그래서 닫기 버튼을 직접 그린다.
/// 자리와 생김새는 맥의 규칙을 그대로 따른다 — **왼쪽 위, 빨간 동그라미**.
/// 오른쪽에 X를 두면 맥에서 창을 닫으려는 손이 매번 헛돈다.
///
/// 옆자리에 노란 동그라미를 두지 않는 이유는 뜻이 다르기 때문이다.
/// 맥에서 노랑은 "Dock으로 최소화"인데 이 앱의 접기는 "제목 줄만 남기고 줄이기"다.
/// 같은 모양을 빌려 쓰면 눌러 보기 전까지 무엇이 일어날지 알 수 없다.
///
/// 시스템의 `standardWindowButton(_:for:)`을 가져다 쓰지 않은 이유는 크기 때문이다.
/// 그 버튼은 12pt로 고정이라, 고밀도 화면에서 글자 크기를 키워 쓰면 혼자만 손톱만 해진다.
/// 여기서는 같은 모양을 글자 크기에 맞춰 그린다.
public final class TrafficLightButton: NSButton {
    private static let fillColor = NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1)    // #FF5F57
    private static let borderColor = NSColor(srgbRed: 0.88, green: 0.29, blue: 0.27, alpha: 1)
    /// 마우스를 올렸을 때 안에 나타나는 ×. 맥과 같은 모양이다.
    private static let glyphColor = NSColor.black.withAlphaComponent(0.55)

    /// 마우스가 버튼 위에 있는가. 그 판단은 감싸는 뷰가 하고, 여기서는 결과만 받는다.
    public var showsGlyph: Bool = false {
        didSet {
            guard showsGlyph != oldValue else { return }
            needsDisplay = true
        }
    }

    public init(help: String) {
        super.init(frame: .zero)
        self.title = ""
        self.isBordered = false
        self.toolTip = help
        self.translatesAutoresizingMaskIntoConstraints = false
        // 버튼이 입력을 가져가면 메모에 글을 쓸 수 없다.
        self.refusesFirstResponder = true
        setAccessibilityLabel(help)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("스토리보드를 사용하지 않는다")
    }

    /// 창이 활성 상태가 아니어도 첫 클릭이 바로 먹혀야 한다.
    /// 맥의 신호등이 그렇게 동작하고, 스티키 노트는 대개 비활성 상태로 떠 있다.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        // 지름은 버튼 높이를 그대로 쓰되, 눌리는 영역은 그보다 넉넉하게 둔다.
        let diameter = min(bounds.width, bounds.height)
        let circle = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        ).insetBy(dx: 0.5, dy: 0.5)

        let path = NSBezierPath(ovalIn: circle)
        // 창이 비활성일 때 회색으로 죽이지 않는다. 스티키 노트는 대부분 비활성 상태로 떠 있어서,
        // 시스템 규칙을 그대로 따르면 닫기 버튼이 늘 회색으로만 보인다.
        Self.fillColor.setFill()
        path.fill()
        Self.borderColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        guard showsGlyph else { return }
        drawGlyph(in: circle)
    }

    private func drawGlyph(in circle: NSRect) {
        let glyph = NSBezierPath()
        glyph.lineWidth = max(1.0, circle.width * 0.11)
        glyph.lineCapStyle = .round
        let inset = circle.width * 0.30
        let box = circle.insetBy(dx: inset, dy: inset)

        glyph.move(to: NSPoint(x: box.minX, y: box.minY))
        glyph.line(to: NSPoint(x: box.maxX, y: box.maxY))
        glyph.move(to: NSPoint(x: box.minX, y: box.maxY))
        glyph.line(to: NSPoint(x: box.maxX, y: box.minY))

        Self.glyphColor.setStroke()
        glyph.stroke()
    }
}

/// 닫기 버튼을 담는 자리. 마우스가 올라오면 × 표시를 켠다.
public final class TrafficLightGroup: NSView {
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    public override func mouseEntered(with event: NSEvent) {
        setGlyphs(true)
    }

    public override func mouseExited(with event: NSEvent) {
        setGlyphs(false)
    }

    private func setGlyphs(_ visible: Bool) {
        for case let button as TrafficLightButton in subviews {
            button.showsGlyph = visible
        }
    }
}

/// 배경 투명도 슬라이더 (OPA-01).
///
/// 두 가지를 시스템 기본에서 바꿨다.
/// - 비활성 창에서도 첫 끌기가 바로 먹힌다. 스티키 노트는 대개 비활성 상태로 떠 있어서,
///   그대로 두면 첫 클릭은 창을 깨우는 데만 쓰이고 투명도를 잡으려면 두 번 손이 간다.
/// - 손잡이와 줄을 직접 그린다. 시스템 손잡이는 흰색이라 밝은 톤의 메모 위에서 사라진다.
public final class OpacitySlider: NSSlider {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public static func make() -> OpacitySlider {
        let slider = OpacitySlider()
        slider.cell = OpacitySliderCell()
        return slider
    }
}

/// 파스텔 배경 위에서도 보이도록 손잡이와 줄을 어둡게 그린다.
final class OpacitySliderCell: NSSliderCell {
    private static let knobColor = NSColor(white: 0.24, alpha: 1.0)
    private static let knobBorderColor = NSColor(white: 1.0, alpha: 0.9)
    private static let trackColor = NSColor.black.withAlphaComponent(0.16)
    private static let filledColor = NSColor.black.withAlphaComponent(0.38)

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let height: CGFloat = 3
        let bar = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        let radius = height / 2

        Self.trackColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

        // 지나온 만큼은 진하게 칠해 지금 값이 어디쯤인지 눈에 들어오게 한다.
        let ratio = (doubleValue - minValue) / max(0.0001, maxValue - minValue)
        var filled = bar
        filled.size.width = bar.width * CGFloat(min(max(ratio, 0), 1))
        Self.filledColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let diameter = min(knobRect.width, knobRect.height) - 1
        let circle = NSRect(
            x: knobRect.midX - diameter / 2,
            y: knobRect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let path = NSBezierPath(ovalIn: circle)
        Self.knobColor.setFill()
        path.fill()
        // 흰 테두리를 얇게 둘러 어두운 배경색을 골랐을 때도 손잡이가 묻히지 않게 한다.
        Self.knobBorderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
