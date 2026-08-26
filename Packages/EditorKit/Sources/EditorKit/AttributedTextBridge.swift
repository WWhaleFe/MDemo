import AppKit
import MarkdownEngine

/// `StyledLine`(서식 표현) ↔ `NSAttributedString`(화면 표시)을 오간다.
///
/// 마크다운 해석은 전부 MarkdownEngine이 하고, 여기서는 그 결과를 글꼴과 색으로만 옮긴다.
/// 이 경계 덕분에 변환 규칙은 창을 띄우지 않고도 시험할 수 있다.
public struct EditorTheme: Sendable {
    public var baseFontSize: CGFloat
    public var textColor: NSColor

    public init(baseFontSize: CGFloat = 13, textColor: NSColor = .black) {
        self.baseFontSize = baseFontSize
        self.textColor = textColor
    }

    /// 제목 단계별 크기. 본문과 확실히 구분되도록 계단을 준다 (TXT-05).
    func fontSize(for block: BlockStyle) -> CGFloat {
        switch block {
        case .heading(let level):
            let scales: [CGFloat] = [1.7, 1.45, 1.25, 1.15, 1.08, 1.0]
            return baseFontSize * scales[max(0, min(level - 1, 5))]
        default:
            return baseFontSize
        }
    }
}

public enum AttributedTextBridge {
    /// 문서 전체를 화면 표시용 문자열로 만든다.
    public static func attributedString(
        from lines: [StyledLine],
        theme: EditorTheme,
        textAlpha: Double
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(attributedString(from: line, theme: theme, textAlpha: textAlpha))
        }
        return result
    }

    public static func attributedString(
        from line: StyledLine,
        theme: EditorTheme,
        textAlpha: Double
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let prefix = visiblePrefix(for: line.block)
        if !prefix.isEmpty {
            result.append(NSAttributedString(
                string: prefix,
                attributes: attributes(block: line.block, inline: [], theme: theme, textAlpha: textAlpha)
            ))
        }
        for span in line.spans {
            result.append(NSAttributedString(
                string: span.text,
                attributes: attributes(block: line.block, inline: span.styles, theme: theme, textAlpha: textAlpha)
            ))
        }
        // 블록 종류를 텍스트에 실어 둔다. 저장할 때 이 값으로 마크다운 기호를 되살린다.
        result.addAttribute(.memoBlockStyle, value: BlockStyleBox(line.block), range: NSRange(location: 0, length: result.length))
        return result
    }

    /// 화면에 보이는 기호. 마크다운 기호는 숨기지만(MD-01), 목록·체크박스는 표식이 없으면 읽을 수 없다.
    public static func visiblePrefix(for block: BlockStyle) -> String {
        switch block {
        case .bullet(let indent):
            return String(repeating: "\t", count: indent) + "• "
        case .ordered(let indent, let number):
            return String(repeating: "\t", count: indent) + "\(number). "
        case .checkbox(let indent, let checked):
            return String(repeating: "\t", count: indent) + (checked ? "☑ " : "☐ ")
        case .quote:
            return "❝ "
        case .divider:
            return "──────────"
        case .heading, .paragraph:
            return ""
        }
    }

    private static func attributes(
        block: BlockStyle,
        inline: InlineStyleTag,
        theme: EditorTheme,
        textAlpha: Double
    ) -> [NSAttributedString.Key: Any] {
        var font = NSFont.systemFont(ofSize: theme.fontSize(for: block))
        var traits: NSFontTraitMask = []

        if case .heading = block { traits.insert(.boldFontMask) }
        if inline.contains(.bold) { traits.insert(.boldFontMask) }
        if inline.contains(.italic) { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        if inline.contains(.code) {
            font = NSFont.monospacedSystemFont(ofSize: theme.fontSize(for: block) * 0.95, weight: .regular)
        }

        var color = theme.textColor.withAlphaComponent(textAlpha)
        if case .quote = block {
            color = color.withAlphaComponent(textAlpha * 0.7)
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if inline.contains(.highlight) {
            attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.45)
        }
        attributes[.memoInlineStyle] = inline.rawValue
        return attributes
    }

    // MARK: - 되돌리기 (화면 → 서식 표현)

    /// 화면의 문자열을 서식 표현으로 되돌린다. 저장 직전에 호출한다.
    public static func styledLines(from attributed: NSAttributedString) -> [StyledLine] {
        let fullText = attributed.string as NSString
        var lines: [StyledLine] = []

        var lineStart = 0
        while lineStart <= fullText.length {
            let lineRange = fullText.lineRange(for: NSRange(location: min(lineStart, fullText.length), length: 0))
            let contentLength = max(0, NSMaxRange(lineRange) - lineStart - trailingNewlineLength(fullText, lineRange))
            let contentRange = NSRange(location: lineStart, length: contentLength)

            lines.append(styledLine(from: attributed, range: contentRange))

            if NSMaxRange(lineRange) <= lineStart { break }
            lineStart = NSMaxRange(lineRange)
            if lineStart == fullText.length { break }
        }
        return lines
    }

    private static func trailingNewlineLength(_ text: NSString, _ lineRange: NSRange) -> Int {
        guard lineRange.length > 0 else { return 0 }
        let last = text.substring(with: NSRange(location: NSMaxRange(lineRange) - 1, length: 1))
        return last == "\n" ? 1 : 0
    }

    private static func styledLine(from attributed: NSAttributedString, range: NSRange) -> StyledLine {
        guard range.length > 0 else { return StyledLine(block: .paragraph, spans: []) }

        var block = BlockStyle.paragraph
        if let box = attributed.attribute(.memoBlockStyle, at: range.location, effectiveRange: nil) as? BlockStyleBox {
            block = box.value
        }

        let prefixLength = (visiblePrefix(for: block) as NSString).length
        let contentRange = NSRange(
            location: range.location + min(prefixLength, range.length),
            length: max(0, range.length - prefixLength)
        )
        guard contentRange.length > 0 else { return StyledLine(block: block, spans: []) }

        var spans: [StyledSpan] = []
        attributed.enumerateAttribute(.memoInlineStyle, in: contentRange) { value, subrange, _ in
            let styles = InlineStyleTag(rawValue: (value as? Int) ?? 0)
            let text = (attributed.string as NSString).substring(with: subrange)
            if var last = spans.last, last.styles == styles {
                last.text += text
                spans[spans.count - 1] = last
            } else {
                spans.append(StyledSpan(text: text, styles: styles))
            }
        }
        return StyledLine(block: block, spans: spans)
    }
}

/// 블록 서식을 텍스트 속성에 실어 나르기 위한 상자.
/// `NSAttributedString`의 속성 값은 참조 타입이어야 해서 열거형을 감쌌다.
final class BlockStyleBox: NSObject {
    let value: BlockStyle
    init(_ value: BlockStyle) { self.value = value }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? BlockStyleBox)?.value == value
    }
    override var hash: Int { value.hashValue }
}

public extension NSAttributedString.Key {
    /// 이 줄의 블록 서식 (제목·목록·체크박스…). 저장 시 마크다운 기호로 되살린다.
    static let memoBlockStyle = NSAttributedString.Key("MemoBlockStyle")
    /// 이 구간의 글자 서식 비트.
    static let memoInlineStyle = NSAttributedString.Key("MemoInlineStyle")
}
