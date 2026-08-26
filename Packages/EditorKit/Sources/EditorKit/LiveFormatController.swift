import AppKit
import MarkdownEngine

/// 입력 중 마크다운 기호를 서식으로 바꾼다 (MD-01 ~ MD-09).
///
/// **이 앱에서 가장 조심스러운 코드다.** 한글은 여러 번의 키 입력이 모여 한 글자가 되는데(조합),
/// 조합이 끝나기 전에 텍스트나 속성을 건드리면 글자가 깨지거나 사라진다 (NFR-08).
///
/// 그래서 규칙은 하나다: **조합 중에는 아무것도 하지 않는다.**
/// 조합이 확정된 뒤에야 그 줄을 검사한다.
@MainActor
public final class LiveFormatController {
    private weak var textView: MemoTextView?
    private let rules: InputRuleSet
    private var theme: EditorTheme
    private var textAlpha: Double

    /// 변환을 스스로 적용하는 동안 다시 호출되는 것을 막는다.
    private var isApplyingFormat = false

    public init(
        textView: MemoTextView,
        rules: InputRuleSet = .m1,
        theme: EditorTheme = EditorTheme(),
        textAlpha: Double = 1.0
    ) {
        self.textView = textView
        self.rules = rules
        self.theme = theme
        self.textAlpha = textAlpha
    }

    public func updateAppearance(theme: EditorTheme, textAlpha: Double) {
        self.theme = theme
        self.textAlpha = textAlpha
    }

    /// 텍스트가 바뀔 때마다 호출된다.
    public func textDidChange() {
        guard !isApplyingFormat else { return }
        guard let textView else { return }

        // 조합 중이면 손대지 않는다. 조합이 끝나면 다음 변경 알림에서 다시 검사한다.
        guard !textView.isComposingText else { return }

        applyRulesToCurrentLine()
    }

    /// 커서가 있는 줄에만 규칙을 적용한다. 문서 전체를 훑지 않아 입력이 느려지지 않는다.
    private func applyRulesToCurrentLine() {
        guard let textView, let textStorage = textView.textStorage else { return }

        let text = textStorage.string as NSString
        let selection = textView.selectedRange()
        guard selection.location <= text.length else { return }

        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let lineText = text.substring(with: lineRange)
        let trimmedLine = lineText.hasSuffix("\n") ? String(lineText.dropLast()) : lineText

        // 규칙은 Character 단위로 다루므로 UTF-16 위치를 변환해 넘긴다.
        let caretUTF16Offset = selection.location - lineRange.location
        guard let caretCharacterOffset = characterOffset(in: trimmedLine, utf16Offset: caretUTF16Offset) else { return }

        guard let match = rules.firstMatch(line: trimmedLine, caretOffset: caretCharacterOffset) else { return }

        apply(match, in: trimmedLine, lineStart: lineRange.location)
    }

    private func apply(_ match: InputRuleMatch, in line: String, lineStart: Int) {
        guard let textView, let textStorage = textView.textStorage else { return }

        let characters = Array(line)
        guard match.range.lowerBound >= 0, match.range.upperBound <= characters.count else { return }

        // 변환 대상 구간을 UTF-16 범위로 바꾼다.
        let prefixUTF16 = String(characters[0..<match.range.lowerBound]).utf16.count
        let matchedUTF16 = String(characters[match.range]).utf16.count
        let replaceRange = NSRange(location: lineStart + prefixUTF16, length: matchedUTF16)

        isApplyingFormat = true
        defer { isApplyingFormat = false }

        // Cmd+Z 한 번으로 원문 기호가 돌아오도록 별도 undo 묶음으로 만든다 (MD-13).
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        guard textView.shouldChangeText(in: replaceRange, replacementString: match.replacement) else { return }

        textStorage.beginEditing()
        switch match.style {
        case .heading, .bulletList, .orderedList, .checkbox, .quote, .divider, .codeBlock:
            applyBlockStyle(match, replaceRange: replaceRange, lineStart: lineStart, textStorage: textStorage)
        case .bold, .italic, .strikethrough, .highlight, .inlineCode:
            applyInlineStyle(match, replaceRange: replaceRange, textStorage: textStorage)
        }
        textStorage.endEditing()

        textView.didChangeText()
    }

    /// 줄 앞머리 기호를 지우고 그 줄 전체에 블록 서식을 건다.
    private func applyBlockStyle(
        _ match: InputRuleMatch,
        replaceRange: NSRange,
        lineStart: Int,
        textStorage: NSTextStorage
    ) {
        let block = blockStyle(for: match.style, line: currentIndent(textStorage: textStorage, lineStart: lineStart))
        textStorage.replaceCharacters(in: replaceRange, with: match.replacement)

        // 화면용 표식(• , ☐ 등)을 넣는다. 마크다운 기호는 저장할 때 되살아난다.
        let prefix = AttributedTextBridge.visiblePrefix(for: block)
        if !prefix.isEmpty {
            textStorage.replaceCharacters(in: NSRange(location: lineStart, length: 0), with: prefix)
        }

        let text = textStorage.string as NSString
        let updatedLine = text.lineRange(for: NSRange(location: lineStart, length: 0))
        let contentLength = updatedLine.length - (text.substring(with: updatedLine).hasSuffix("\n") ? 1 : 0)
        guard contentLength > 0 else { return }

        let styleRange = NSRange(location: lineStart, length: contentLength)
        textStorage.addAttribute(.memoBlockStyle, value: BlockStyleBox(block), range: styleRange)
        textStorage.addAttribute(.font, value: NSFont.systemFont(ofSize: theme.fontSize(for: block)), range: styleRange)
        if case .heading = block {
            let bold = NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: theme.fontSize(for: block)),
                toHaveTrait: .boldFontMask
            )
            textStorage.addAttribute(.font, value: bold, range: styleRange)
        }
    }

    /// 감싼 기호를 지우고 안쪽 글자에만 서식을 건다.
    private func applyInlineStyle(
        _ match: InputRuleMatch,
        replaceRange: NSRange,
        textStorage: NSTextStorage
    ) {
        textStorage.replaceCharacters(in: replaceRange, with: match.replacement)

        let styledRange = NSRange(location: replaceRange.location, length: (match.replacement as NSString).length)
        guard styledRange.length > 0 else { return }

        let existing = (textStorage.attribute(.memoInlineStyle, at: styledRange.location, effectiveRange: nil) as? Int) ?? 0
        let combined = InlineStyleTag(rawValue: existing).union(inlineTag(for: match.style))

        let block = (textStorage.attribute(.memoBlockStyle, at: styledRange.location, effectiveRange: nil) as? BlockStyleBox)?.value ?? .paragraph
        let styled = AttributedTextBridge.attributedString(
            from: StyledLine(block: block, spans: [StyledSpan(text: match.replacement, styles: combined)]),
            theme: theme,
            textAlpha: textAlpha
        )
        // 블록 표식이 앞에 붙지 않는 인라인 변환이므로 내용만 가져다 쓴다.
        let contentOnly = styled.attributedSubstring(
            from: NSRange(location: 0, length: min(styled.length, styledRange.length))
        )
        textStorage.replaceCharacters(in: styledRange, with: contentOnly)
    }

    private func currentIndent(textStorage: NSTextStorage, lineStart: Int) -> Int {
        let text = textStorage.string as NSString
        let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
        let line = text.substring(with: lineRange)
        var tabs = 0
        for character in line {
            if character == "\t" { tabs += 1 } else { break }
        }
        return tabs
    }

    private func blockStyle(for style: InlineStyle, line indent: Int) -> BlockStyle {
        switch style {
        case .heading(let level): return .heading(level: level)
        case .bulletList: return .bullet(indent: indent)
        case .orderedList: return .ordered(indent: indent, number: 1)
        case .checkbox(let checked): return .checkbox(indent: indent, checked: checked)
        case .quote: return .quote
        case .divider: return .divider
        default: return .paragraph
        }
    }

    private func inlineTag(for style: InlineStyle) -> InlineStyleTag {
        switch style {
        case .bold: return .bold
        case .italic: return .italic
        case .strikethrough: return .strikethrough
        case .highlight: return .highlight
        case .inlineCode: return .code
        default: return []
        }
    }

    /// UTF-16 위치를 Character 위치로 바꾼다.
    /// 한글은 둘이 같지만 이모지 같은 문자는 어긋나므로 반드시 변환해야 한다.
    private func characterOffset(in line: String, utf16Offset: Int) -> Int? {
        guard utf16Offset >= 0 else { return nil }
        guard let index = String.Index(line.utf16.index(line.utf16.startIndex, offsetBy: utf16Offset, limitedBy: line.utf16.endIndex) ?? line.utf16.endIndex, within: line) else {
            return nil
        }
        return line.distance(from: line.startIndex, to: index)
    }
}
