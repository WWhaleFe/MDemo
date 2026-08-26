import AppKit
import CoreGraphics

/// 화면 밀도를 읽어 읽기 편한 글자 크기와 창 크기를 계산한다 (SET-01, TXT-03).
///
/// 같은 15pt라도 화면에 따라 실제 크기가 크게 다르다.
/// macOS는 보통 인치당 110포인트를 가정하는데, 고밀도로 설정된 화면은 190을 넘기도 한다.
/// 그런 화면에서 15pt는 물리적으로 8.6pt 크기로 보인다 — 눈이 아플 수밖에 없다.
///
/// 그래서 "몇 pt로 할까"가 아니라 "실제로 몇 mm로 보이게 할까"를 기준으로 잡는다.
public enum DisplayMetrics {
    /// macOS가 표준으로 가정하는 밀도. 이 값을 기준으로 얼마나 촘촘한지를 잰다.
    public static let referencePointsPerInch: CGFloat = 110

    /// 표준 밀도 화면에서 편안한 값들. 여기에 밀도 비율을 곱해 실제 값을 얻는다.
    private static let baseFontSize: CGFloat = 14
    private static let baseMemoSize = NSSize(width: 330, height: 380)

    public struct Recommendation: Sendable {
        public var fontSize: CGFloat
        public var memoSize: NSSize
        /// 계산 근거. 설정 화면과 로그에서 왜 이 값이 나왔는지 보여줄 때 쓴다.
        public var pointsPerInch: CGFloat
        public var scale: CGFloat
    }

    public static func recommended(for screen: NSScreen? = NSScreen.main) -> Recommendation {
        guard let screen else {
            return Recommendation(
                fontSize: baseFontSize,
                memoSize: baseMemoSize,
                pointsPerInch: referencePointsPerInch,
                scale: 1
            )
        }

        let density = pointsPerInch(of: screen) ?? referencePointsPerInch
        // 지나치게 크거나 작아지지 않도록 배율을 제한한다.
        let scale = min(max(density / referencePointsPerInch, 1.0), 2.0)

        let fontSize = snapToStep(baseFontSize * scale)
        let size = NSSize(
            width: baseMemoSize.width * scale,
            height: baseMemoSize.height * scale
        )

        return Recommendation(
            fontSize: fontSize,
            memoSize: fitToScreen(size, screen: screen),
            pointsPerInch: density,
            scale: scale
        )
    }

    /// 화면의 인치당 포인트 수. 물리 크기를 알 수 없는 화면이면 nil.
    public static func pointsPerInch(of screen: NSScreen) -> CGFloat? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let millimeters = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
        // 물리 크기를 보고하지 않는 화면(일부 외부 모니터·가상 화면)이 있다.
        guard millimeters.width > 1 else { return nil }

        let inches = millimeters.width / 25.4
        return screen.frame.width / inches
    }

    /// 계산한 크기를 화면 안에 들어오게 다듬는다. 창이 화면을 뒤덮으면 스티키 노트가 아니다.
    private static func fitToScreen(_ size: NSSize, screen: NSScreen) -> NSSize {
        let visible = screen.visibleFrame
        return NSSize(
            width: min(max(size.width, 280), visible.width * 0.4),
            height: min(max(size.height, 320), visible.height * 0.6)
        )
    }

    /// 글자 크기는 정해진 단계 중 가장 가까운 값으로 맞춘다 (TXT-03).
    private static func snapToStep(_ value: CGFloat) -> CGFloat {
        EditorTheme.fontSizeSteps.min { abs($0 - value) < abs($1 - value) } ?? EditorTheme.defaultFontSize
    }
}
