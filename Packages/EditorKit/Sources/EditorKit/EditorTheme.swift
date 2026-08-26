import AppKit
import MarkdownEngine

/// 에디터의 글꼴과 색. 메모별이 아니라 전역 설정이다 (TXT-02, TXT-03).
public struct EditorTheme: Sendable {
    /// 사용할 글꼴 가족 이름. nil이면 권장 목록에서 자동으로 고른다.
    public var fontFamily: String?
    public var baseFontSize: CGFloat
    public var textColor: NSColor

    /// 본문 글자 크기 7단계 (TXT-03).
    /// 고해상도 화면에서 13pt 안팎은 너무 작아, 눈에 편한 구간으로 올려 잡았다.
    public static let fontSizeSteps: [CGFloat] = [14, 16, 18, 20, 24, 28, 32]
    public static let defaultFontSize: CGFloat = 18

    public init(
        fontFamily: String? = nil,
        baseFontSize: CGFloat = EditorTheme.defaultFontSize,
        textColor: NSColor = .black
    ) {
        self.fontFamily = fontFamily
        self.baseFontSize = baseFontSize
        self.textColor = textColor
    }

    /// 제목 단계별 크기. 본문과 확실히 구분되도록 계단을 준다 (TXT-05).
    public func fontSize(for block: BlockStyle) -> CGFloat {
        switch block {
        case .heading(let level):
            let scales: [CGFloat] = [1.7, 1.45, 1.25, 1.15, 1.08, 1.0]
            return baseFontSize * scales[max(0, min(level - 1, 5))]
        default:
            return baseFontSize
        }
    }

    /// 이 줄·이 구간에 쓸 글꼴을 만든다.
    public func font(for block: BlockStyle, inline: InlineStyleTag = []) -> NSFont {
        let size = fontSize(for: block)

        // 코드는 글자 폭이 일정해야 읽히므로 선택한 글꼴과 무관하게 고정폭을 쓴다.
        if inline.contains(.code) {
            return NSFont.monospacedSystemFont(ofSize: size * 0.95, weight: .regular)
        }

        var traits: NSFontTraitMask = []
        if case .heading = block { traits.insert(.boldFontMask) }
        if inline.contains(.bold) { traits.insert(.boldFontMask) }
        if inline.contains(.italic) { traits.insert(.italicFontMask) }

        return FontResolver.font(family: fontFamily, size: size, traits: traits)
    }
}
