import AppKit
import MarkdownEngine

/// 슬래시 명령 연결 (SL-01 ~ SL-04).
///
/// 줄 시작에서 `/`를 치면 팝업이 뜨고, 이어 입력하면 좁혀지며, 고르면 그 줄이 해당 블록이 된다.
/// 마크다운 기호를 외우지 않아도 되는 경로라 실제로는 이쪽을 더 많이 쓰게 된다.
extension LiveFormatController {
    /// 텍스트가 바뀔 때마다 팝업 상태를 갱신한다.
    func updateSlashPopup() {
        guard let textView else { return }
        // 조합 중에는 팝업을 건드리지 않는다 (NFR-08).
        guard !textView.isComposingText else { return }

        guard let query = slashQuery() else {
            if slashPopup.isVisible { slashPopup.hide() }
            return
        }

        let matches = SlashCommandCatalog.filter(query)
        guard !matches.isEmpty else {
            slashPopup.hide()
            return
        }
        guard let window = textView.window else { return }
        slashPopup.show(commands: matches, below: caretRectOnScreen(), in: window)
    }

    /// 커서 앞의 `/`부터 지금까지 입력한 글자. 슬래시 상태가 아니면 nil.
    ///
    /// `/`는 줄 시작이나 공백 뒤에서만 명령으로 본다 (SL-01).
    /// 경로(`앱/설정`)를 쓰다가 팝업이 뜨면 성가시기 때문이다.
    private func slashQuery() -> String? {
        guard let textView, let textStorage = textView.textStorage else { return nil }

        let text = textStorage.string as NSString
        let caret = textView.selectedRange()
        guard caret.length == 0, caret.location <= text.length else { return nil }

        let lineRange = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let caretInLine = caret.location - lineRange.location
        guard caretInLine > 0 else { return nil }

        let lineText = text.substring(with: lineRange) as NSString
        let typed = lineText.substring(to: caretInLine)

        guard let slashIndex = typed.lastIndex(of: "/") else { return nil }
        let beforeSlash = typed[typed.startIndex..<slashIndex]
        guard beforeSlash.isEmpty || beforeSlash.hasSuffix(" ") || beforeSlash.hasSuffix("\t") else { return nil }

        let query = String(typed[typed.index(after: slashIndex)...])
        // 공백이 들어오면 명령을 그만 찾는다 — 그냥 문장을 쓰는 중이다.
        guard !query.contains(" ") else { return nil }
        return query
    }

    /// 커서 위치를 화면 좌표로 바꾼다. 팝업을 커서 아래 붙이는 데 쓴다.
    private func caretRectOnScreen() -> NSRect {
        guard let textView, let window = textView.window else { return .zero }
        let caret = textView.selectedRange()
        let rectInView = textView.firstRect(forCharacterRange: caret, actualRange: nil)
        // firstRect는 이미 화면 좌표를 돌려준다. 실패하면 창 왼쪽 위를 쓴다.
        if rectInView != .zero { return rectInView }
        return NSRect(origin: window.frame.origin, size: .zero)
    }

    /// 팝업이 키를 가로챘으면 true.
    func handleSlashKeyDown(_ event: NSEvent) -> Bool {
        slashPopup.handleKeyDown(event)
    }

    /// 명령을 골랐을 때: 입력한 `/명령` 글자를 지우고 그 줄을 해당 블록으로 바꾼다.
    func applySlashCommand(_ command: SlashCommand) {
        guard let textView, let textStorage = textView.textStorage else { return }

        let text = textStorage.string as NSString
        let caret = textView.selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: min(caret.location, text.length), length: 0))
        let caretInLine = caret.location - lineRange.location
        let lineText = text.substring(with: lineRange) as NSString
        let typed = lineText.substring(to: caretInLine)

        guard let slashIndex = typed.lastIndex(of: "/") else { return }
        let slashOffset = typed.distance(from: typed.startIndex, to: slashIndex)
        let removeLocation = lineRange.location + (typed as NSString).substring(to: slashOffset).utf16.count
        let removeRange = NSRange(location: removeLocation, length: caret.location - removeLocation)

        let oldBlock = blockStyle(in: textStorage, at: lineRange.location)
        let newPrefix = AttributedTextBridge.visiblePrefix(for: command.block)
        let oldPrefix = AttributedTextBridge.visiblePrefix(for: oldBlock)

        guard textView.shouldChangeText(in: removeRange, replacementString: "") else { return }

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        // 1. 입력한 `/명령` 지우기
        textStorage.replaceCharacters(in: removeRange, with: "")
        // 2. 이전 표식을 새 블록의 표식으로 갈아 끼우기
        let prefixRange = NSRange(location: lineRange.location, length: (oldPrefix as NSString).length)
        textStorage.replaceCharacters(in: prefixRange, with: newPrefix)
        applyBlockAttributes(command.block, lineStart: lineRange.location, textStorage: textStorage)
        textStorage.endEditing()

        let newCaret = lineRange.location + (newPrefix as NSString).length
        textView.setSelectedRange(NSRange(location: min(newCaret, (textStorage.string as NSString).length), length: 0))
        textView.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha, block: command.block)
        textView.didChangeText()
    }
}
