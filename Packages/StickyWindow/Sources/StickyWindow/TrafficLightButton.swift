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
    private var hovered = false

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    public override func draw(_ dirtyRect: NSRect) {
        if hovered {
            TopBarButton.hoverColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public static func make() -> OpacitySlider {
        let slider = OpacitySlider()
        slider.cell = OpacitySliderCell()
        return slider
    }
}

/// 파스텔 배경 위에서도 보이도록 손잡이와 줄을 어둡게 그린다.
///
/// 손잡이는 얇은 세로 막대(알약 모양)를 불투명한 회색으로 칠한다. 반투명으로 칠하면 뒤의 줄이 비쳐 겹친 부분이 얼룩져 보인다.
/// 색은 다른 아이콘의 "검정 62%"를 파스텔 메모 위에서 본 색과 비슷한 불투명 회색이다. 줄은 손잡이가 돋보이게 옅게 둔다.
final class OpacitySliderCell: NSSliderCell {
    private static let knobColor = NSColor(srgbRed: 0.369, green: 0.373, blue: 0.380, alpha: 1)
    private static let trackColor = NSColor.black.withAlphaComponent(0.30)

    /// 손잡이 막대의 폭. 줄 양 끝도 이 폭만큼만 남겨, 손잡이가 끝까지 가면 줄 끝에 딱 닿아 보이게 한다.
    private static let pillWidth: CGFloat = 6

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let height: CGFloat = 3
        // 손잡이 가운데가 움직이는 범위는 줄 양 끝에서 손잡이 칸 절반씩 안쪽이다.
        // 줄을 그 범위(+ 손잡이 막대 절반)로 맞춰야 손잡이가 끝까지 간 것으로 보인다.
        let inset = max(0, knobThickness / 2 - Self.pillWidth / 2)
        let bar = NSRect(x: rect.minX + inset, y: rect.midY - height / 2, width: max(0, rect.width - inset * 2), height: height)
        let radius = height / 2

        Self.trackColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let height = max(10, min(knobRect.height - 1, 18))
        let width = Self.pillWidth
        let pill = NSRect(
            x: knobRect.midX - width / 2,
            y: knobRect.midY - height / 2,
            width: width,
            height: height
        )
        Self.knobColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: width / 2, yRadius: width / 2).fill()
    }
}
