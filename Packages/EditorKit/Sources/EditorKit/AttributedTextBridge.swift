import AppKit
import MarkdownEngine

/// `StyledLine`(서식 표현) ↔ `NSAttributedString`(화면 표시)을 오간다.
///
/// 마크다운 해석은 전부 MarkdownEngine이 하고, 여기서는 그 결과를 글꼴과 색으로만 옮긴다.
/// 이 경계 덕분에 변환 규칙은 창을 띄우지 않고도 시험할 수 있다.
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
                attributes: attributes(block: line.block, span: StyledSpan(text: ""), theme: theme, textAlpha: textAlpha)
            ))
        }
        for span in line.spans {
            result.append(NSAttributedString(
                string: span.text,
                attributes: attributes(block: line.block, span: span, theme: theme, textAlpha: textAlpha)
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
            // 단계마다 다른 기호를 쓴다 — • / ◦ / ▪. 번호 목록의 1. / a. / i.와 같은 방식이다.
            // 모두 한 글자라 표식 길이가 단계에 따라 달라지지 않는다.
            return String(repeating: "\t", count: indent) + bulletSymbol(forIndent: indent) + " "
        case .ordered(let indent, let number):
            // 단계마다 다른 꼴을 쓴다 — 1. / a. / i. (MD-03).
            return String(repeating: "\t", count: indent)
                + OrderedListMarker.text(number: number, indent: indent) + " "
        case .checkbox(let indent, let checked):
            return String(repeating: "\t", count: indent) + (checked ? "☑ " : "☐ ")
        case .quote:
            return "❝ "
        case .divider:
            return "──────────"
        case .heading, .paragraph, .codeBlock, .tableRow:
            return ""
        }
    }

    /// 글머리 기호. 네 번째 단계부터는 처음 기호로 돌아간다.
    public static func bulletSymbol(forIndent indent: Int) -> String {
        let symbols = ["•", "◦", "▪"]
        return symbols[max(0, indent) % symbols.count]
    }

    /// `span`의 글자는 쓰지 않고 서식(굵게·색…)만 읽는다.
    private static func attributes(
        block: BlockStyle,
        span: StyledSpan,
        theme: EditorTheme,
        textAlpha: Double
    ) -> [NSAttributedString.Key: Any] {
        let inline = span.styles
        let font = theme.font(for: block, inline: inline)

        var alpha = textAlpha
        if case .quote = block {
            alpha *= 0.7
        }
        let color = InlineColorPalette.foreground(hex: span.textColor, theme: theme, alpha: alpha)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]

        // 표도 코드 박스와 같은 방식으로 줄 뒤에 띠를 그린다 (MD-14).
        if case .tableRow = block {
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = Self.codeBlockInset.width
            paragraph.headIndent = Self.codeBlockInset.width
            paragraph.tailIndent = -Self.codeBlockInset.width
            attributes[.paragraphStyle] = paragraph
        }

        // 코드 박스는 상자 안에 들어간 것처럼 좌우를 들여 쓴다.
        // 상자 자체는 MemoLayoutManager가 글자 뒤에 그린다 (MD-10).
        if case .codeBlock = block {
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = Self.codeBlockInset.width
            paragraph.headIndent = Self.codeBlockInset.width
            paragraph.tailIndent = -Self.codeBlockInset.width
            attributes[.paragraphStyle] = paragraph
        }
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if inline.contains(.highlight) {
            attributes[.backgroundColor] = InlineColorPalette.highlightBackground(hex: span.highlightColor)
            if let hex = span.highlightColor {
                attributes[.memoHighlightColor] = hex
            }
        }
        if let hex = span.textColor {
            attributes[.memoTextColor] = hex
        }
        attributes[.memoInlineStyle] = inline.rawValue
        return attributes
    }

    /// 코드 상자 안쪽 여백. 그리는 쪽과 글자를 미는 쪽이 같은 값을 써야 어긋나지 않는다.
    public static let codeBlockInset = NSSize(width: 10, height: 2)

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
        attributed.enumerateAttributes(in: contentRange) { attributes, subrange, _ in
            let span = StyledSpan(
                text: (attributed.string as NSString).substring(with: subrange),
                styles: InlineStyleTag(rawValue: (attributes[.memoInlineStyle] as? Int) ?? 0),
                textColor: attributes[.memoTextColor] as? String,
                highlightColor: attributes[.memoHighlightColor] as? String
            )
            if var last = spans.last, last.hasSameFormat(as: span) {
                last.text += span.text
                spans[spans.count - 1] = last
            } else {
                spans.append(span)
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
    /// 이 구간의 글자 색 ("#RRGGBB"). 없으면 테마 색.
    static let memoTextColor = NSAttributedString.Key("MemoTextColor")
    /// 이 구간의 형광펜 색 ("#RRGGBB"). 형광이 켜져 있는데 이 값이 없으면 기본 노랑.
    static let memoHighlightColor = NSAttributedString.Key("MemoHighlightColor")
}
