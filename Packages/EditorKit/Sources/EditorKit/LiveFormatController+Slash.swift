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
        // 조합 중에도 갱신한다. 팝업은 글자를 읽기만 하므로 안전하고,
        // 여기서 멈추면 한글로 키워드를 칠 때 목록이 따라오지 않는다 (NFR-08).

        guard let query = slashQuery() else {
            if slashPopup.isVisible { slashPopup.hide() }
            return
        }

        let matches = SlashCommandCatalog.filter(query)
        guard !matches.isEmpty else {
            // 한글은 완성되기 전에 자모("ㅊ") 상태를 거치는데, 이때는 어떤 키워드와도 맞지 않는다.
            // 그렇다고 목록을 닫으면 글자를 칠 때마다 깜빡이고, 닫는 과정에서 창을 건드려
            // 조합까지 흔들린다. 조합이 끝날 때까지는 이전 목록을 그대로 둔다.
            if !textView.isComposingText {
                slashPopup.hide()
            }
            return
        }
        guard let window = textView.window else { return }
        slashPopup.show(commands: matches, query: query, below: caretRectOnScreen(), in: window)
    }

    /// 커서 앞의 `/`부터 지금까지 입력한 글자. 슬래시 상태가 아니면 nil.
    ///
    /// `/`는 줄 시작이나 공백 뒤에서만 명령으로 본다 (SL-01).
    /// 경로(`앱/설정`)를 쓰다가 팝업이 뜨면 성가시기 때문이다.
    private func slashQuery() -> String? {
        guard let textView, let textStorage = textView.textStorage else { return nil }

        let text = textStorage.string as NSString

        // 조합 중에는 입력기가 조합 구간을 통째로 선택 상태로 두기도 한다.
        // 그럴 때는 조합 구간의 끝을 커서로 본다. 그러지 않으면 한글로 칠 때만 목록이 사라진다.
        let caret: NSRange
        if textView.isComposingText {
            caret = NSRange(location: NSMaxRange(textView.markedRange()), length: 0)
        } else {
            caret = textView.selectedRange()
            guard caret.length == 0 else { return nil }
        }
        guard caret.location <= text.length else { return nil }

        let lineRange = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let caretInLine = caret.location - lineRange.location
        guard caretInLine > 0 else { return nil }

        let lineText = text.substring(with: lineRange) as NSString
        let typed = lineText.substring(to: caretInLine)

        guard let slashIndex = typed.lastIndex(of: "/") else { return nil }
        let beforeSlash = typed[typed.startIndex..<slashIndex]
        guard beforeSlash.isEmpty || beforeSlash.hasSuffix(" ") || beforeSlash.hasSuffix("\t") else { return nil }

        let query = String(typed[typed.index(after: slashIndex)...])
        // 명령 이름에 띄어쓰기가 있으니("제목 1", "번호 목록") 공백도 받는다.
        // 대신 길이를 제한해, `/` 뒤에 긴 문장을 쓰는 중에는 명령으로 보지 않는다.
        // 맞는 명령이 없으면 호출한 쪽에서 목록을 닫는다.
        guard query.count <= 20 else { return nil }
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
    ///
    /// 한글 조합 중일 때가 까다롭다. 조합 중 엔터는 입력기가 "조합 확정"에 먼저 쓰기 때문에,
    /// 그대로 두면 명령이 적용되지 않고 사용자는 엔터를 두 번 눌러야 한다.
    /// 그래서 확정 키에 한해 조합을 먼저 확정한 뒤 명령을 적용한다.
    /// 방향키 같은 나머지 키는 입력기가 쓸 수 있으니 넘기지 않는다.
    func handleSlashKeyDown(_ event: NSEvent) -> Bool {
        guard slashPopup.isVisible else { return false }

        let isConfirmKey = [36, 76, 48].contains(event.keyCode)  // Return, Enter, Tab

        if textView?.isComposingText == true {
            guard isConfirmKey else { return false }
            textView?.commitComposition()
        }
        return slashPopup.handleKeyDown(event)
    }

    /// 명령을 골랐을 때: 입력한 `/명령` 글자를 지우고 그 줄을 해당 블록으로 바꾼다.
    public func applySlashCommand(_ command: SlashCommand) {
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

        // 미뤄서 적용하는 사이에 글자가 바뀌었을 수 있다. 범위를 다시 확인한다.
        guard removeRange.location >= 0,
              NSMaxRange(removeRange) <= text.length,
              removeRange.length > 0
        else { return }
        guard textView.shouldChangeText(in: removeRange, replacementString: "") else { return }

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        // 1. 입력한 `/명령` 지우기
        textStorage.replaceCharacters(in: removeRange, with: "")

        // 2. 이전 표식을 새 블록의 표식으로 갈아 끼우기.
        //    앞에서 글자를 지웠으므로 남은 길이 안에서만 다뤄야 한다.
        let remaining = (textStorage.string as NSString).length
        let oldPrefixLength = min((oldPrefix as NSString).length, max(0, remaining - lineRange.location))
        if lineRange.location <= remaining {
            let prefixRange = NSRange(location: lineRange.location, length: oldPrefixLength)
            textStorage.replaceCharacters(in: prefixRange, with: newPrefix)
            applyBlockAttributes(command.block, lineStart: lineRange.location, textStorage: textStorage)
        }
        textStorage.endEditing()

        let newCaret = lineRange.location + (newPrefix as NSString).length
        textView.setSelectedRange(NSRange(location: min(newCaret, (textStorage.string as NSString).length), length: 0))
        textView.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha, block: command.block)
        textView.didChangeText()
    }
}
