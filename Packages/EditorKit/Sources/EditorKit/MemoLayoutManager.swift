import AppKit
import MarkdownEngine

/// 코드 박스와 표의 바탕을 글자 뒤에 그린다 (MD-10, MD-14).
///
/// 글자 배경색(`.backgroundColor`)으로는 상자를 만들 수 없다.
/// 그 속성은 글자가 있는 만큼만 칠해져, 짧은 줄과 긴 줄의 오른쪽 끝이 들쭉날쭉해진다.
/// 줄 전체를 덮는 상자는 줄 조각(line fragment)을 아는 레이아웃 매니저만 그릴 수 있다.
///
/// 서식마다 뷰를 만들지 않는다는 원칙(§4-5)도 여기서 지켜진다 — 상자는 뷰가 아니라 그림이다.
final class MemoLayoutManager: NSLayoutManager {
    /// 바탕 한 종류의 색.
    ///
    /// 검정을 옅게 까는 대신 회색을 쓴다. 메모 배경이 노랑·분홍 같은 파스텔이라
    /// 검정을 섞으면 그저 어두운 노랑이 되어 본문과 잘 구분되지 않는다.
    /// 회색을 얹으면 색이 빠지면서 "다른 판" 위에 있는 것처럼 보인다.
    private struct BandStyle: Equatable {
        var fill: NSColor
        var border: NSColor

        static let code = BandStyle(
            fill: NSColor(srgbRed: 0.45, green: 0.46, blue: 0.48, alpha: 0.20),
            border: NSColor(srgbRed: 0.30, green: 0.31, blue: 0.33, alpha: 0.35)
        )
        /// 표는 코드보다 옅게 깐다. 표 안의 글은 읽을 내용이라 바탕이 세면 눈이 피로하다.
        static let table = BandStyle(
            fill: NSColor(srgbRed: 0.45, green: 0.46, blue: 0.48, alpha: 0.10),
            border: NSColor(srgbRed: 0.30, green: 0.31, blue: 0.33, alpha: 0.28)
        )
    }

    private static let cornerRadius: CGFloat = 5

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, textStorage.length > 0 else { return }

        // 이어지는 줄은 한 덩어리로 모아 한 번에 그린다.
        // 줄마다 따로 그리면 줄 사이에 실선 자국이 남는다.
        var band: (rect: NSRect, style: BandStyle)?

        enumerateLineFragments(forGlyphRange: glyphsToShow) { _, usedRect, container, glyphRange, _ in
            let charRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let style = self.bandStyle(at: charRange.location, in: textStorage)

            // 바탕은 글자 폭이 아니라 줄 전체 폭을 덮어야 한다.
            let full = NSRect(
                x: origin.x + container.lineFragmentPadding,
                y: origin.y + usedRect.minY,
                width: container.size.width - container.lineFragmentPadding * 2,
                height: usedRect.height
            )

            switch (band, style) {
            case (let current?, let style?) where current.style == style:
                band = (current.rect.union(full), style)
            case (let current?, _):
                Self.draw(current.rect, style: current.style)
                band = style.map { (full, $0) }
            case (nil, let style?):
                band = (full, style)
            case (nil, nil):
                break
            }
        }
        if let pending = band {
            Self.draw(pending.rect, style: pending.style)
        }
    }

    private func bandStyle(at location: Int, in textStorage: NSTextStorage) -> BandStyle? {
        guard location < textStorage.length else { return nil }
        let value = textStorage.attribute(.memoBlockStyle, at: location, effectiveRange: nil)
        switch (value as? BlockStyleBox)?.value {
        case .codeBlock: return .code
        case .tableRow: return .table
        default: return nil
        }
    }

    private static func draw(_ rect: NSRect, style: BandStyle) {
        let box = rect.insetBy(dx: 0, dy: -AttributedTextBridge.codeBlockInset.height)
        let path = NSBezierPath(roundedRect: box, xRadius: cornerRadius, yRadius: cornerRadius)
        style.fill.setFill()
        path.fill()
        style.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
