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
        let rawLine = text.substring(with: lineRange)
        let line = rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine

        // 이 줄에 이미 걸린 블록 서식과 화면 표식(`• `, `☐ `)을 분리한다.
        let block = currentBlock(in: textStorage, at: lineRange.location)
        let visiblePrefix = AttributedTextBridge.visiblePrefix(for: block)
        let prefixUTF16Length = (visiblePrefix as NSString).length

        guard line.hasPrefix(visiblePrefix) else { return }
        let content = String(line.dropFirst(visiblePrefix.count))

        // 규칙은 Character 단위로 다루므로 UTF-16 위치를 변환해 넘긴다.
        let caretInContentUTF16 = selection.location - lineRange.location - prefixUTF16Length
        guard caretInContentUTF16 >= 0,
              let caretOffset = characterOffset(in: content, utf16Offset: caretInContentUTF16)
        else { return }

        let context = InputRuleContext(content: content, caretOffset: caretOffset, block: block)
        guard let match = rules.firstMatch(context) else { return }

        apply(
            match,
            content: content,
            contentStart: lineRange.location + prefixUTF16Length,
            lineStart: lineRange.location,
            currentBlock: block
        )
    }

    private func apply(
        _ match: InputRuleMatch,
        content: String,
        contentStart: Int,
        lineStart: Int,
        currentBlock: BlockStyle
    ) {
        guard let textView, let textStorage = textView.textStorage else { return }

        let characters = Array(content)
        guard match.range.lowerBound >= 0, match.range.upperBound <= characters.count else { return }

        let prefixUTF16 = String(characters[0..<match.range.lowerBound]).utf16.count
        let matchedUTF16 = String(characters[match.range]).utf16.count
        let replaceRange = NSRange(location: contentStart + prefixUTF16, length: matchedUTF16)

        isApplyingFormat = true
        defer { isApplyingFormat = false }

        // Cmd+Z 한 번으로 원문 기호가 돌아오도록 별도 undo 묶음으로 만든다 (MD-13).
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        guard textView.shouldChangeText(in: replaceRange, replacementString: match.replacement) else { return }

        textStorage.beginEditing()
        switch match.outcome {
        case .block(let newBlock):
            applyBlockChange(
                to: newBlock,
                from: currentBlock,
                markerRange: replaceRange,
                replacement: match.replacement,
                lineStart: lineStart,
                textStorage: textStorage
            )
        case .inline(let tag):
            applyInlineStyle(tag, markerRange: replaceRange, replacement: match.replacement, textStorage: textStorage)
        }
        textStorage.endEditing()

        textView.didChangeText()
    }

    /// 입력한 기호를 지우고, 화면 표식을 새 블록의 것으로 갈아 끼운다.
    ///
    /// 글머리 목록(`• `)에서 체크박스(`☐ `)로 바뀌는 경우처럼 이미 표식이 있을 수 있으므로,
    /// 옛 표식을 지운 자리에 새 표식을 넣는다.
    private func applyBlockChange(
        to newBlock: BlockStyle,
        from oldBlock: BlockStyle,
        markerRange: NSRange,
        replacement: String,
        lineStart: Int,
        textStorage: NSTextStorage
    ) {
        textStorage.replaceCharacters(in: markerRange, with: replacement)

        let oldPrefix = AttributedTextBridge.visiblePrefix(for: oldBlock)
        let newPrefix = AttributedTextBridge.visiblePrefix(for: newBlock)
        let oldPrefixRange = NSRange(location: lineStart, length: (oldPrefix as NSString).length)
        if oldPrefixRange.length > 0 || !newPrefix.isEmpty {
            textStorage.replaceCharacters(in: oldPrefixRange, with: newPrefix)
        }

        let text = textStorage.string as NSString
        let updatedLine = text.lineRange(for: NSRange(location: min(lineStart, text.length), length: 0))
        let hasNewline = text.substring(with: updatedLine).hasSuffix("\n")
        let contentLength = updatedLine.length - (hasNewline ? 1 : 0)
        guard contentLength > 0 else { return }

        let styleRange = NSRange(location: lineStart, length: contentLength)
        textStorage.addAttribute(.memoBlockStyle, value: BlockStyleBox(newBlock), range: styleRange)

        var font = NSFont.systemFont(ofSize: theme.fontSize(for: newBlock))
        if case .heading = newBlock {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        textStorage.addAttribute(.font, value: font, range: styleRange)

        // 다음에 입력하는 글자도 같은 블록 서식을 이어받게 한다.
        textView?.typingAttributes[.memoBlockStyle] = BlockStyleBox(newBlock)
        textView?.typingAttributes[.font] = font
    }

    /// 감싼 기호를 지우고 안쪽 글자에만 서식을 건다.
    private func applyInlineStyle(
        _ tag: InlineStyleTag,
        markerRange: NSRange,
        replacement: String,
        textStorage: NSTextStorage
    ) {
        textStorage.replaceCharacters(in: markerRange, with: replacement)

        let styledRange = NSRange(location: markerRange.location, length: (replacement as NSString).length)
        guard styledRange.length > 0 else { return }

        let existing = (textStorage.attribute(.memoInlineStyle, at: styledRange.location, effectiveRange: nil) as? Int) ?? 0
        let combined = InlineStyleTag(rawValue: existing).union(tag)
        let block = currentBlock(in: textStorage, at: styledRange.location)

        let styled = AttributedTextBridge.attributedString(
            from: StyledLine(block: block, spans: [StyledSpan(text: replacement, styles: combined)]),
            theme: theme,
            textAlpha: textAlpha
        )
        // 블록 표식이 앞에 붙지 않는 인라인 변환이므로 내용만 가져다 쓴다.
        let prefixLength = (AttributedTextBridge.visiblePrefix(for: block) as NSString).length
        let contentRange = NSRange(location: prefixLength, length: max(0, styled.length - prefixLength))
        guard contentRange.length == styledRange.length else { return }
        textStorage.replaceCharacters(in: styledRange, with: styled.attributedSubstring(from: contentRange))

        // 닫는 기호 뒤에 이어 쓰는 글자는 서식 없이 돌아가야 한다.
        textView?.resetTypingAttributes(theme: theme, textAlpha: textAlpha, block: block)
    }

    private func currentBlock(in textStorage: NSTextStorage, at location: Int) -> BlockStyle {
        guard location < textStorage.length,
              let box = textStorage.attribute(.memoBlockStyle, at: location, effectiveRange: nil) as? BlockStyleBox
        else { return .paragraph }
        return box.value
    }

    /// UTF-16 위치를 Character 위치로 바꾼다.
    /// 한글은 둘이 같지만 이모지 같은 문자는 어긋나므로 반드시 변환해야 한다.
    private func characterOffset(in line: String, utf16Offset: Int) -> Int? {
        guard utf16Offset >= 0 else { return nil }
        guard let utf16Index = line.utf16.index(line.utf16.startIndex, offsetBy: utf16Offset, limitedBy: line.utf16.endIndex),
              let index = String.Index(utf16Index, within: line)
        else { return nil }
        return line.distance(from: line.startIndex, to: index)
    }
}
