import AppKit
import MarkdownEngine

/// 서식 단축키 (KEY-01 ~ KEY-09).
///
/// 슬래시 명령이 "무엇이 있는지 모를 때" 쓰는 길이라면, 단축키는 손에 익은 뒤 쓰는 길이다.
/// 둘 다 같은 결과로 이어져야 하므로, 블록·글자 서식을 바꾸는 방법은 한 곳에 모아 둔다.
extension LiveFormatController {
    /// 단축키를 처리했으면 true. 편집기는 그 키를 무시한다.
    func handleFormattingKey(_ event: NSEvent) -> Bool {
        guard let textView else { return false }
        // 조합 중에는 입력기가 먼저 쓰게 둔다 (NFR-08).
        guard !textView.isComposingText else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }

        let hasShift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch (key, hasShift) {
        case ("b", false):                      // KEY-01
            toggleInlineStyle(.bold)
        case ("i", false):                      // KEY-02
            toggleInlineStyle(.italic)
        case ("x", true):                       // KEY-04
            toggleInlineStyle(.strikethrough)
        case ("h", true):                       // KEY-05
            toggleInlineStyle(.highlight)
        case ("1", false), ("2", false), ("3", false):   // KEY-06
            let level = Int(key) ?? 1
            toggleBlock(.heading(level: level))
        case ("c", true):                       // KEY-07
            toggleBlock(.checkbox(indent: currentIndent(), checked: false))
        case ("\r", _):                         // KEY-09
            return toggleCheckboxAtCaret()
        default:
            return false
        }
        return true
    }

    // MARK: - 글자 서식 (KEY-01, 02, 04, 05)

    /// 고른 구간의 서식을 켜고 끈다. 고른 것이 없으면 다음에 칠 글자에 적용된다.
    ///
    /// 단축키와 서식 막대가 같은 길을 쓴다 — 결과가 갈라지지 않게 진입점을 하나로 둔다.
    public func toggleInlineStyle(_ tag: InlineStyleTag) {
        guard let textView, let textStorage = textView.textStorage else { return }

        let selection = textView.selectedRange()
        guard selection.length > 0 else {
            toggleTypingStyle(tag)
            return
        }
        guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }

        // 구간 전체가 이미 그 서식이면 끄고, 아니면 켠다.
        let shouldRemove = isEntireRange(selection, styledWith: tag, in: textStorage)

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        textStorage.enumerateAttribute(.memoInlineStyle, in: selection) { value, subrange, _ in
            let current = InlineStyleTag(rawValue: (value as? Int) ?? 0)
            let updated = shouldRemove ? current.subtracting(tag) : current.union(tag)
            applyInlineAttributes(updated, to: subrange, in: textStorage)
        }
        textStorage.endEditing()

        textView.didChangeText()
    }

    private func toggleTypingStyle(_ tag: InlineStyleTag) {
        guard let textView else { return }
        let current = InlineStyleTag(rawValue: (textView.typingAttributes[.memoInlineStyle] as? Int) ?? 0)
        let updated = current.contains(tag) ? current.subtracting(tag) : current.union(tag)

        let block = blockAtCaret()
        textView.typingAttributes[.memoInlineStyle] = updated.rawValue
        textView.typingAttributes[.font] = currentTheme.font(for: block, inline: updated)
        textView.typingAttributes[.strikethroughStyle] =
            updated.contains(.strikethrough) ? NSUnderlineStyle.single.rawValue : 0
        if updated.contains(.highlight) {
            let hex = textView.typingAttributes[.memoHighlightColor] as? String
            textView.typingAttributes[.backgroundColor] = InlineColorPalette.highlightBackground(hex: hex)
        } else {
            textView.typingAttributes[.backgroundColor] = NSColor.clear
            textView.typingAttributes[.memoHighlightColor] = nil
        }
    }

    private func isEntireRange(_ range: NSRange, styledWith tag: InlineStyleTag, in textStorage: NSTextStorage) -> Bool {
        var isEverywhere = true
        textStorage.enumerateAttribute(.memoInlineStyle, in: range) { value, _, stop in
            let current = InlineStyleTag(rawValue: (value as? Int) ?? 0)
            if !current.contains(tag) {
                isEverywhere = false
                stop.pointee = true
            }
        }
        return isEverywhere
    }

    /// 서식 비트에 맞춰 글꼴·취소선·형광 배경을 다시 입힌다.
    func applyInlineAttributes(_ styles: InlineStyleTag, to range: NSRange, in textStorage: NSTextStorage) {
        guard range.length > 0 else { return }
        let block = blockStyle(in: textStorage, at: range.location)

        textStorage.addAttribute(.memoInlineStyle, value: styles.rawValue, range: range)
        textStorage.addAttribute(.font, value: currentTheme.font(for: block, inline: styles), range: range)

        if styles.contains(.strikethrough) {
            textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        } else {
            textStorage.removeAttribute(.strikethroughStyle, range: range)
        }

        if styles.contains(.highlight) {
            // 구간 안에 형광펜 색이 여럿일 수 있다. 조각마다 제 색을 칠한다.
            textStorage.enumerateAttribute(.memoHighlightColor, in: range) { value, subrange, _ in
                textStorage.addAttribute(
                    .backgroundColor,
                    value: InlineColorPalette.highlightBackground(hex: value as? String),
                    range: subrange
                )
            }
        } else {
            textStorage.removeAttribute(.backgroundColor, range: range)
            textStorage.removeAttribute(.memoHighlightColor, range: range)
        }
    }

    // MARK: - 글자 색 · 형광펜 색

    /// 고른 글자의 색을 바꾼다. nil이면 기본 글자색으로 되돌린다.
    /// 고른 것이 없으면 다음에 칠 글자에 적용된다.
    public func setTextColor(_ hex: String?) {
        guard let textView, let textStorage = textView.textStorage else { return }
        let hex = InlineColor.normalized(hex)

        let selection = textView.selectedRange()
        guard selection.length > 0 else {
            textView.typingAttributes[.memoTextColor] = hex
            textView.typingAttributes[.foregroundColor] = foregroundColor(hex: hex, block: blockAtCaret())
            return
        }
        guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        // 줄마다 블록이 다르다(인용은 흐리게, 체크된 항목은 더 흐리게). 줄 단위로 색을 입힌다.
        textStorage.enumerateAttribute(.memoBlockStyle, in: selection) { value, subrange, _ in
            let block = (value as? BlockStyleBox)?.value ?? .paragraph
            if let hex {
                textStorage.addAttribute(.memoTextColor, value: hex, range: subrange)
            } else {
                textStorage.removeAttribute(.memoTextColor, range: subrange)
            }
            textStorage.addAttribute(.foregroundColor, value: foregroundColor(hex: hex, block: block), range: subrange)
        }
        textStorage.endEditing()

        textView.didChangeText()
    }

    /// 고른 글자에 형광펜을 칠한다. `hex`가 nil이면 기본 노랑.
    public func setHighlightColor(_ hex: String?) {
        applyHighlight(enabled: true, hex: InlineColor.normalized(hex))
    }

    /// 고른 글자의 형광펜을 지운다.
    public func removeHighlight() {
        applyHighlight(enabled: false, hex: nil)
    }

    private func applyHighlight(enabled: Bool, hex: String?) {
        guard let textView, let textStorage = textView.textStorage else { return }

        let selection = textView.selectedRange()
        guard selection.length > 0 else {
            let current = InlineStyleTag(rawValue: (textView.typingAttributes[.memoInlineStyle] as? Int) ?? 0)
            let updated = enabled ? current.union(.highlight) : current.subtracting(.highlight)
            textView.typingAttributes[.memoInlineStyle] = updated.rawValue
            textView.typingAttributes[.memoHighlightColor] = enabled ? hex : nil
            textView.typingAttributes[.backgroundColor] =
                enabled ? InlineColorPalette.highlightBackground(hex: hex) : NSColor.clear
            return
        }
        guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        if enabled, let hex {
            textStorage.addAttribute(.memoHighlightColor, value: hex, range: selection)
        } else {
            textStorage.removeAttribute(.memoHighlightColor, range: selection)
        }
        textStorage.enumerateAttribute(.memoInlineStyle, in: selection) { value, subrange, _ in
            let current = InlineStyleTag(rawValue: (value as? Int) ?? 0)
            let updated = enabled ? current.union(.highlight) : current.subtracting(.highlight)
            applyInlineAttributes(updated, to: subrange, in: textStorage)
        }
        textStorage.endEditing()

        textView.didChangeText()
    }

    /// 그 줄에 맞는 글자색. 인용은 흐리게, 체크된 항목은 더 흐리게 (CHK-02).
    func foregroundColor(hex: String?, block: BlockStyle) -> NSColor {
        var alpha = currentTextAlpha
        if case .quote = block { alpha *= 0.7 }
        if case .checkbox(_, true) = block { alpha *= 0.45 }
        return InlineColorPalette.foreground(hex: hex, theme: currentTheme, alpha: alpha)
    }

    // MARK: - 블록 서식 (KEY-06, KEY-07)

    /// 현재 줄을 그 블록으로 바꾼다. 이미 같은 블록이면 본문으로 되돌린다.
    public func toggleBlock(_ block: BlockStyle) {
        guard let textView, let textStorage = textView.textStorage else { return }

        let text = textStorage.string as NSString
        let caret = textView.selectedRange()
        guard caret.location <= text.length else { return }

        let lineRange = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let oldBlock = blockStyle(in: textStorage, at: lineRange.location)
        let newBlock = isSameKind(oldBlock, block) ? .paragraph : block

        let oldPrefix = AttributedTextBridge.visiblePrefix(for: oldBlock)
        let newPrefix = AttributedTextBridge.visiblePrefix(for: newBlock)
        let prefixRange = NSRange(
            location: lineRange.location,
            length: min((oldPrefix as NSString).length, lineRange.length)
        )
        guard textView.shouldChangeText(in: prefixRange, replacementString: newPrefix) else { return }

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: prefixRange, with: newPrefix)
        applyBlockAttributes(newBlock, lineStart: lineRange.location, textStorage: textStorage)
        textStorage.endEditing()

        let shift = (newPrefix as NSString).length - prefixRange.length
        textView.setSelectedRange(NSRange(location: max(lineRange.location, caret.location + shift), length: 0))
        textView.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha, block: newBlock)
        textView.didChangeText()
    }

    /// 같은 종류인지 본다. 제목은 단계까지 같아야 되돌린다 (Cmd+1을 두 번 누르면 본문).
    private func isSameKind(_ left: BlockStyle, _ right: BlockStyle) -> Bool {
        switch (left, right) {
        case (.heading(let a), .heading(let b)): return a == b
        case (.checkbox, .checkbox): return true
        case (.bullet, .bullet): return true
        case (.ordered, .ordered): return true
        case (.quote, .quote): return true
        default: return false
        }
    }

    /// 커서가 있는 줄의 체크박스를 켜고 끈다 (KEY-09).
    private func toggleCheckboxAtCaret() -> Bool {
        guard let textView, let textStorage = textView.textStorage else { return false }
        let caret = textView.selectedRange()
        let lineRange = (textStorage.string as NSString)
            .lineRange(for: NSRange(location: min(caret.location, textStorage.length), length: 0))
        return handleCheckboxToggle(atCharacterIndex: lineRange.location)
    }

    private func blockAtCaret() -> BlockStyle {
        guard let textView, let textStorage = textView.textStorage else { return .paragraph }
        let caret = textView.selectedRange()
        let lineRange = (textStorage.string as NSString)
            .lineRange(for: NSRange(location: min(caret.location, textStorage.length), length: 0))
        return blockStyle(in: textStorage, at: lineRange.location)
    }

    private func currentIndent() -> Int {
        blockAtCaret().indent
    }
}
