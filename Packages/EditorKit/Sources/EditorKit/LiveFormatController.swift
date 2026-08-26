import AppKit
import MarkdownEngine

/// 입력 중 마크다운 기호를 서식으로 바꾼다 (MD-01 ~ MD-09).
///
/// **이 앱에서 가장 조심스러운 코드다.** 한글은 여러 번의 키 입력이 모여 한 글자가 되는데(조합),
/// 조합이 끝나기 전에 텍스트나 속성을 건드리면 글자가 깨지거나 사라진다 (NFR-08).
///
/// 그래서 규칙은 하나다: **조합 중에는 아무것도 하지 않는다.**
/// 조합이 확정된 뒤에야 그 줄을 검사한다.
///
/// 목록을 이어가고 들여쓰는 동작은 `LiveFormatController+Lists.swift`에 있다.
@MainActor
public final class LiveFormatController {
    weak var textView: MemoTextView?
    private let rules: InputRuleSet
    private(set) var currentTheme: EditorTheme
    private(set) var currentTextAlpha: Double

    /// 변환을 스스로 적용하는 동안 다시 호출되는 것을 막는다.
    private var isApplyingFormat = false

    /// 슬래시 명령 팝업 (SL-01). 목록은 팝업이 열릴 때만 만들어진다.
    let slashPopup = SlashCommandPopup()

    public init(
        textView: MemoTextView,
        rules: InputRuleSet = .m1,
        theme: EditorTheme = EditorTheme(),
        textAlpha: Double = 1.0
    ) {
        self.textView = textView
        self.rules = rules
        self.currentTheme = theme
        self.currentTextAlpha = textAlpha

        // 엔터·탭·클릭은 목록 문맥을 알아야 하므로 이쪽에서 처리한다.
        textView.onNewline = { [weak self] in self?.handleNewline() ?? false }
        textView.onIndent = { [weak self] deeper in self?.handleIndent(deeper: deeper) ?? false }
        textView.onToggleCheckbox = { [weak self] index in
            self?.handleCheckboxToggle(atCharacterIndex: index) ?? false
        }
        textView.onKeyDown = { [weak self] event in
            self?.handleSlashKeyDown(event) ?? false
        }

        slashPopup.onSelect = { [weak self] command in
            self?.applySlashCommand(command)
        }
        // 팝업이 뜨고 닫히는 어느 순간에도 입력은 편집기가 받아야 한다.
        slashPopup.onRestoreFocus = { [weak textView] in
            guard let textView, let window = textView.window else { return }
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        }
    }

    deinit {
        // 팝업은 부모 창에 붙은 자식 창이라 명시적으로 떼어 낸다.
        MainActor.assumeIsolated { slashPopup.release() }
    }

    /// 창이 닫히거나 숨겨질 때 팝업도 함께 정리한다.
    public func dismissPopups() {
        slashPopup.hide()
    }

    /// 슬래시 팝업이 떠 있는가. 동작 확인과 테스트에 쓴다.
    public var isSlashPopupVisible: Bool { slashPopup.isVisible }

    /// 지금 팝업에 보이는 명령 목록.
    public var visibleSlashCommands: [SlashCommand] { slashPopup.visibleCommands }

    public func updateAppearance(theme: EditorTheme, textAlpha: Double) {
        self.currentTheme = theme
        self.currentTextAlpha = textAlpha
    }

    // MARK: - 변환 진입점

    /// 텍스트가 바뀔 때마다 호출된다.
    public func textDidChange() {
        guard !isApplyingFormat else { return }
        guard let textView else { return }

        // 조합 중이면 손대지 않는다. 조합이 끝나면 다음 변경 알림에서 다시 검사한다.
        guard !textView.isComposingText else { return }

        applyRulesToCurrentLine()
        updateSlashPopup()
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
        let block = blockStyle(in: textStorage, at: lineRange.location)
        let visiblePrefix = AttributedTextBridge.visiblePrefix(for: block)

        // 속성이 말하는 블록과 실제 글자가 어긋나면(붙여넣기·되돌리기 등) 문단으로 보고 검사한다.
        // 여기서 그냥 돌아가 버리면 그 줄에서는 어떤 변환도 다시 일어나지 않는다.
        let effectiveBlock = line.hasPrefix(visiblePrefix) ? block : .paragraph
        let effectivePrefix = line.hasPrefix(visiblePrefix) ? visiblePrefix : ""
        let prefixUTF16Length = (effectivePrefix as NSString).length
        let content = String(line.dropFirst(effectivePrefix.count))

        // 규칙은 Character 단위로 다루므로 UTF-16 위치를 변환해 넘긴다.
        let caretInContentUTF16 = selection.location - lineRange.location - prefixUTF16Length
        guard caretInContentUTF16 >= 0,
              let caretOffset = characterOffset(in: content, utf16Offset: caretInContentUTF16)
        else { return }

        let context = InputRuleContext(content: content, caretOffset: caretOffset, block: effectiveBlock)
        guard let match = rules.firstMatch(context) else { return }

        apply(
            match,
            content: content,
            contentStart: lineRange.location + prefixUTF16Length,
            lineStart: lineRange.location,
            currentBlock: effectiveBlock
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

        beginFormatting()
        defer { endFormatting() }

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

        applyBlockAttributes(newBlock, lineStart: lineStart, textStorage: textStorage)

        // 같은 줄에 이어 쓰는 글자도 이 블록 서식을 따르게 한다.
        // 줄이 바뀔 때는 handleNewline이 다시 정해 주므로 여기서 넘어가지 않는다.
        textView?.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha, block: newBlock)
    }

    /// 줄 전체에 블록 서식과 글꼴을 입힌다.
    func applyBlockAttributes(_ block: BlockStyle, lineStart: Int, textStorage: NSTextStorage) {
        let text = textStorage.string as NSString
        guard lineStart < text.length else { return }

        let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
        let hasNewline = text.substring(with: lineRange).hasSuffix("\n")
        let contentLength = lineRange.length - (hasNewline ? 1 : 0)
        guard contentLength > 0 else { return }

        let styleRange = NSRange(location: lineStart, length: contentLength)
        textStorage.addAttribute(.memoBlockStyle, value: BlockStyleBox(block), range: styleRange)
        textStorage.addAttribute(.font, value: currentTheme.font(for: block), range: styleRange)
    }

    /// 체크된 항목은 취소선과 흐린 색으로 표시한다 (CHK-02).
    func applyCheckedAppearance(_ block: BlockStyle, lineStart: Int, textStorage: NSTextStorage) {
        guard case .checkbox(_, let checked) = block else { return }

        let text = textStorage.string as NSString
        guard lineStart < text.length else { return }
        let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
        let hasNewline = text.substring(with: lineRange).hasSuffix("\n")
        let prefixLength = (AttributedTextBridge.visiblePrefix(for: block) as NSString).length
        let contentLength = lineRange.length - (hasNewline ? 1 : 0) - prefixLength
        guard contentLength > 0 else { return }

        let contentRange = NSRange(location: lineStart + prefixLength, length: contentLength)
        if checked {
            textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
            textStorage.addAttribute(
                .foregroundColor,
                value: currentTheme.textColor.withAlphaComponent(currentTextAlpha * 0.45),
                range: contentRange
            )
        } else {
            textStorage.removeAttribute(.strikethroughStyle, range: contentRange)
            textStorage.addAttribute(
                .foregroundColor,
                value: currentTheme.textColor.withAlphaComponent(currentTextAlpha),
                range: contentRange
            )
        }
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
        let block = blockStyle(in: textStorage, at: styledRange.location)

        textStorage.addAttribute(.font, value: currentTheme.font(for: block, inline: combined), range: styledRange)
        textStorage.addAttribute(.memoInlineStyle, value: combined.rawValue, range: styledRange)

        if combined.contains(.strikethrough) {
            textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: styledRange)
        }
        if combined.contains(.highlight) {
            textStorage.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.45),
                range: styledRange
            )
        }

        // 닫는 기호 뒤에 이어 쓰는 글자는 서식 없이 돌아가야 한다.
        textView?.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha, block: block)
    }

    // MARK: - 공용 도구

    func blockStyle(in textStorage: NSTextStorage, at location: Int) -> BlockStyle {
        guard location < textStorage.length,
              let box = textStorage.attribute(.memoBlockStyle, at: location, effectiveRange: nil) as? BlockStyleBox
        else { return .paragraph }
        return box.value
    }

    /// 변환을 적용하는 동안에는 되돌리기를 한 묶음으로 만들고 재진입을 막는다 (MD-13).
    func beginFormatting() {
        isApplyingFormat = true
        textView?.undoManager?.beginUndoGrouping()
    }

    func endFormatting() {
        textView?.undoManager?.endUndoGrouping()
        isApplyingFormat = false
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
