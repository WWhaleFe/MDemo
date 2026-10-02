import AppKit
import MemoCore

/// 스티키 창의 배경 레이어. 둥근 모서리와 배경 알파를 담당한다 (WIN-02, OPA-01).
public final class StickyRootView: NSView {
    private var baseColor: NSColor = .white
    private var backgroundAlpha: Double = 0.95

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        applyBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("스토리보드를 사용하지 않는다")
    }

    /// 마우스가 들어오고 나갈 때 알린다 (OPA-04).
    public var onHoverChange: ((Bool) -> Void)?

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
        onHoverChange?(true)
    }

    public override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    /// 배경색만 바꾼다. 텍스트에는 영향이 없다 (OPA-01).
    public func apply(colorHex: String, backgroundAlpha alpha: Double) {
        if let rgb = MemoColor.components(fromHex: colorHex) {
            baseColor = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1.0)
        }
        backgroundAlpha = MemoMeta.clampBackgroundAlpha(alpha)
        applyBackground()
    }

    private func applyBackground() {
        layer?.backgroundColor = baseColor.withAlphaComponent(backgroundAlpha).cgColor
    }
}

/// 창 상단 손잡이 영역. 여기를 잡으면 창이 끌린다.
///
/// 예전에는 두 번 누르면 접혔다. 그 자리는 이제 제목을 쓰는 칸이라(TXT-06),
/// 접기는 머리 영역 오른쪽의 버튼으로 옮겼다 (WIN-08).
public final class StickyHeaderView: NSView {
    public override func mouseDragged(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
