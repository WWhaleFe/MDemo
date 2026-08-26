import AppKit
import MarkdownEngine

/// 목록을 노션처럼 다루기 위한 동작들.
///
/// 엔터로 항목이 이어지고, 빈 항목에서 엔터를 치면 목록을 빠져나오며,
/// Tab으로 단계를 조절하고, 체크박스는 클릭으로 토글된다.
/// 이것들이 없으면 목록은 "한 줄짜리 서식"에 그쳐 실제로 쓸 수 없다.
extension LiveFormatController {
    /// 엔터 처리. 기본 동작을 대신했으면 true.
    public func handleNewline() -> Bool {
        guard let textView, let textStorage = textView.textStorage else { return false }
        // 조합 중이면 손대지 않는다 (NFR-08).
        guard !textView.isComposingText else { return false }

        let text = textStorage.string as NSString
        let caret = textView.selectedRange()
        guard caret.location <= text.length else { return false }

        let lineRange = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let block = blockStyle(in: textStorage, at: lineRange.location)
        guard block.continuesOnNewline else {
            // 목록이 아니면 기본 동작에 맡기되, 다음 줄이 앞 줄 서식을 물려받지 않게 한다 (TXT-05).
            textView.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha)
            return false
        }

        let prefix = AttributedTextBridge.visiblePrefix(for: block)
        let rawLine = text.substring(with: lineRange)
        let line = rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine
        let content = line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line

        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return exitList(block: block, lineRange: lineRange, textStorage: textStorage, textView: textView)
        }
        return continueList(block: block, caret: caret, textStorage: textStorage, textView: textView)
    }

    /// 빈 항목에서 엔터 → 목록을 빠져나온다.
    ///
    /// 한 단계 들여쓴 상태였다면 먼저 한 단계 나오고, 그다음에야 목록을 벗어난다.
    private func exitList(
        block: BlockStyle,
        lineRange: NSRange,
        textStorage: NSTextStorage,
        textView: MemoTextView
    ) -> Bool {
        if block.indent > 0 {
            return changeIndent(by: -1)
        }

        let text = textStorage.string as NSString
        let hasNewline = text.substring(with: lineRange).hasSuffix("\n")
        let contentRange = NSRange(
            location: lineRange.location,
            length: lineRange.length - (hasNewline ? 1 : 0)
        )
        guard textView.shouldChangeText(in: contentRange, replacementString: "") else { return false }

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: contentRange, with: "")
        textStorage.endEditing()

        textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
        textView.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha)
        textView.didChangeText()
        return true
    }

    /// 다음 줄에 같은 종류의 항목을 만든다.
    private func continueList(
        block: BlockStyle,
        caret: NSRange,
        textStorage: NSTextStorage,
        textView: MemoTextView
    ) -> Bool {
        let nextBlock = block.nextItem
        let insertion = "\n" + AttributedTextBridge.visiblePrefix(for: nextBlock)
        guard textView.shouldChangeText(in: caret, replacementString: insertion) else { return false }

        beginFormatting()
        defer { endFormatting() }

        let attributed = NSMutableAttributedString(
            string: insertion,
            attributes: [
                .font: currentTheme.font(for: nextBlock),
                .foregroundColor: currentTheme.textColor.withAlphaComponent(currentTextAlpha),
            ]
        )
        // 줄바꿈 문자는 앞 줄에 속하므로, 블록 표시는 새 줄 부분에만 건다.
        let newLinePortion = NSRange(location: 1, length: attributed.length - 1)
        if newLinePortion.length > 0 {
            attributed.addAttribute(.memoBlockStyle, value: BlockStyleBox(nextBlock), range: newLinePortion)
        }

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: caret, with: attributed)
        textStorage.endEditing()

        textView.setSelectedRange(NSRange(location: caret.location + attributed.length, length: 0))
        textView.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha, block: nextBlock)
        textView.didChangeText()
        return true
    }

    /// Tab / Shift+Tab (KEY-08).
    public func handleIndent(deeper: Bool) -> Bool {
        changeIndent(by: deeper ? 1 : -1)
    }

    private func changeIndent(by delta: Int) -> Bool {
        guard let textView, let textStorage = textView.textStorage else { return false }
        guard !textView.isComposingText else { return false }

        let text = textStorage.string as NSString
        let caret = textView.selectedRange()
        guard caret.location <= text.length else { return false }

        let lineRange = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let block = blockStyle(in: textStorage, at: lineRange.location)
        guard block.continuesOnNewline else { return false }

        let newIndent = max(0, min(block.indent + delta, 4))
        guard newIndent != block.indent else { return true }

        let newBlock = block.withIndent(newIndent)
        let oldPrefix = AttributedTextBridge.visiblePrefix(for: block)
        let newPrefix = AttributedTextBridge.visiblePrefix(for: newBlock)
        let prefixRange = NSRange(location: lineRange.location, length: (oldPrefix as NSString).length)
        guard textView.shouldChangeText(in: prefixRange, replacementString: newPrefix) else { return false }

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: prefixRange, with: newPrefix)
        applyBlockAttributes(newBlock, lineStart: lineRange.location, textStorage: textStorage)
        textStorage.endEditing()

        let shift = (newPrefix as NSString).length - prefixRange.length
        textView.setSelectedRange(NSRange(location: max(lineRange.location, caret.location + shift), length: 0))
        textView.didChangeText()
        return true
    }

    /// 체크박스 표식을 눌렀을 때 체크를 뒤집는다 (CHK-01).
    /// 표식이 아닌 글자를 눌렀다면 아무 일도 하지 않고 false를 돌려준다.
    public func handleCheckboxToggle(atCharacterIndex index: Int) -> Bool {
        guard let textView, let textStorage = textView.textStorage else { return false }

        let text = textStorage.string as NSString
        guard index >= 0, index <= text.length, text.length > 0 else { return false }

        let lineRange = text.lineRange(for: NSRange(location: min(index, text.length - 1), length: 0))
        let block = blockStyle(in: textStorage, at: lineRange.location)
        guard case .checkbox(let indent, let checked) = block else { return false }

        // 표식 위를 눌렀을 때만 토글한다. 글자를 누르면 커서만 옮겨야 한다.
        let prefix = AttributedTextBridge.visiblePrefix(for: block)
        let prefixLength = (prefix as NSString).length
        guard index <= lineRange.location + prefixLength else { return false }

        let newBlock = BlockStyle.checkbox(indent: indent, checked: !checked)
        let prefixRange = NSRange(location: lineRange.location, length: prefixLength)
        let newPrefix = AttributedTextBridge.visiblePrefix(for: newBlock)
        guard textView.shouldChangeText(in: prefixRange, replacementString: newPrefix) else { return false }

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: prefixRange, with: newPrefix)
        applyBlockAttributes(newBlock, lineStart: lineRange.location, textStorage: textStorage)
        // 체크된 항목은 흐리게 + 취소선으로 보여준다 (CHK-02).
        applyCheckedAppearance(newBlock, lineStart: lineRange.location, textStorage: textStorage)
        textStorage.endEditing()

        textView.didChangeText()
        return true
    }
}

extension BlockStyle {
    /// 엔터를 쳤을 때 다음 줄로 이어지는 종류인가.
    var continuesOnNewline: Bool {
        switch self {
        case .bullet, .ordered, .checkbox: return true
        default: return false
        }
    }

    /// 이어질 다음 항목. 번호는 하나 올라가고, 체크박스는 체크가 풀린 상태로 시작한다.
    var nextItem: BlockStyle {
        switch self {
        case .bullet(let indent): return .bullet(indent: indent)
        case .ordered(let indent, let number): return .ordered(indent: indent, number: number + 1)
        case .checkbox(let indent, _): return .checkbox(indent: indent, checked: false)
        default: return .paragraph
        }
    }

    func withIndent(_ indent: Int) -> BlockStyle {
        switch self {
        case .bullet: return .bullet(indent: indent)
        case .ordered(_, let number): return .ordered(indent: indent, number: number)
        case .checkbox(_, let checked): return .checkbox(indent: indent, checked: checked)
        default: return self
        }
    }
}
