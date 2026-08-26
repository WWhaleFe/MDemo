import AppKit

/// 프레임리스 스티키 노트 창 (WIN-02).
///
/// 투명도 원칙(설계서 §3): `alphaValue`는 항상 1.0으로 두고,
/// 배경 레이어와 텍스트 색에 각각 알파를 적용해 배경만 투명하고 글씨는 또렷한 상태를 만든다.
public final class StickyPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        alphaValue = 1.0              // 절대 낮추지 않는다 — 배경/텍스트 알파는 따로 관리한다
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false  // 닫기는 숨김이다 (WIN-10). 해제는 컨트롤러가 결정한다
        minSize = NSSize(width: 180, height: 120)

        // 전체 화면 앱 위에서도 보이게 한다 (WIN-04)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// 프레임리스 창은 기본적으로 키 윈도우가 되지 못해 입력을 받을 수 없다.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    /// 항상 위 토글 (WIN-03).
    public func setAlwaysOnTop(_ isOnTop: Bool) {
        level = isOnTop ? .floating : .normal
    }
}
