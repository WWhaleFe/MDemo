import AppKit
import Services

extension AppearanceMode {
    /// 앱 전체(목록 창, 흐름 줄, 메모 창)에 화면 모드를 적용한다. 시스템을 따를 때는 nil.
    ///
    /// `animated`이면 떠 있는 창마다 0.18초 교차 페이드를 건다. 바꾸기 직전 화면 층에 페이드 전환을 걸어 두면
    /// 다음 그리기(새 모드)가 이전 그림 위로 녹아들 듯 바뀐다. 스냅숏을 따로 만들지 않아 가볍고, 연달아 바꿔도 막히지 않는다.
    @MainActor
    public func apply(animated: Bool = false) {
        if animated {
            for window in NSApp.windows where window.isVisible {
                // 제목 막대까지 함께 바뀌도록 창 테두리 층(contentView의 부모)에 건다.
                guard let layer = (window.contentView?.superview ?? window.contentView)?.layer else { continue }
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.18
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "화면모드전환")
            }
        }
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// 목록 창 단추에 쓰는 기호.
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}
