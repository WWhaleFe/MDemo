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
/// M2에서 더블클릭 접기(WIN-08)와 8방향 리사이즈 히트존이 여기에 붙는다.
public final class StickyHeaderView: NSView {
    public override func mouseDragged(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
