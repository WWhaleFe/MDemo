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
                width: self.bandWidth(in: container),
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

    // MARK: - 이미지 (IMG-03)

    /// 이미지 첨부 글자 하나가 차지하는 영역 (글 상자 좌표). 아직 배치가 안 됐으면 nil.
    func attachmentRect(forCharacterIndex index: Int) -> NSRect? {
        guard let textStorage, index >= 0, index < textStorage.length,
              textStorage.attribute(.attachment, at: index, effectiveRange: nil) is MemoImageAttachment
        else { return nil }
        ensureLayout(forCharacterRange: NSRange(location: index, length: 1))
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = self.location(forGlyphAt: glyph)
        let size = attachmentSize(forGlyphAt: glyph)
        guard size.width > 0, size.height > 0 else { return nil }
        // 첨부의 바닥이 기준선이므로, 기준선에서 높이만큼 올라간 곳이 윗변이다.
        // `attachmentBounds`가 바닥을 4pt 내려 놓았으니 그만큼 되돌린다.
        return NSRect(
            x: line.minX + location.x,
            y: line.minY + location.y - size.height + MemoImageAttachment.baselineDrop,
            width: size.width,
            height: size.height
        )
    }

    /// 고른 이미지에 테두리와 네 모서리 손잡이를 그린다.
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let textView = firstTextView else { return }
        let selected = MainActor.assumeIsolated { (textView as? MemoTextView)?.selectedImageIndex }
        guard let index = selected, let rect = attachmentRect(forCharacterIndex: index) else { return }
        let glyph = glyphIndexForCharacter(at: index)
        guard NSLocationInRange(glyph, glyphsToShow) else { return }

        let box = rect.offsetBy(dx: origin.x, dy: origin.y)
        let ink = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
        ink.setStroke()
        let border = NSBezierPath(rect: box.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()

        for handle in MemoImageHandle.rects(in: box) {
            NSColor.white.setFill()
            NSBezierPath(rect: handle.rect).fill()
            ink.setStroke()
            let outline = NSBezierPath(rect: handle.rect.insetBy(dx: 0.75, dy: 0.75))
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    /// 바탕 띠의 폭. 줄바꿈을 끄면 글 상자 폭이 끝없이 넓어지므로 그때는 텍스트 뷰 폭을 따른다.
    private func bandWidth(in container: NSTextContainer) -> CGFloat {
        if !container.widthTracksTextView, let textView = container.textView {
            // 그리기는 늘 메인 스레드에서 일어난다.
            let inset = MainActor.assumeIsolated { textView.bounds.width - textView.textContainerInset.width * 2 }
            return inset - container.lineFragmentPadding * 2
        }
        return container.size.width - container.lineFragmentPadding * 2
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

/// 고른 이미지의 모서리 손잡이 (IMG-03). 그리는 쪽과 누르는 쪽이 같은 치수를 쓴다.
/// 손잡이는 이미지 영역 안쪽에 둔다. 바깥에 두면 선택을 풀 때 지워지지 않고 남는다.
struct MemoImageHandle {
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight

        /// 왼쪽 모서리는 오른쪽으로 끌면 줄어든다.
        var growsToTheRight: Bool { self == .topRight || self == .bottomRight }
    }

    static let size: CGFloat = 10

    let corner: Corner
    let rect: NSRect

    static func rects(in box: NSRect) -> [MemoImageHandle] {
        let s = size
        return [
            MemoImageHandle(corner: .topLeft, rect: NSRect(x: box.minX, y: box.minY, width: s, height: s)),
            MemoImageHandle(corner: .topRight, rect: NSRect(x: box.maxX - s, y: box.minY, width: s, height: s)),
            MemoImageHandle(corner: .bottomLeft, rect: NSRect(x: box.minX, y: box.maxY - s, width: s, height: s)),
            MemoImageHandle(corner: .bottomRight, rect: NSRect(x: box.maxX - s, y: box.maxY - s, width: s, height: s)),
        ]
    }
}
