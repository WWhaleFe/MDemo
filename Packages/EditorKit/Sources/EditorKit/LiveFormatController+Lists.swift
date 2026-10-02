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

        // 표 안에서는 엔터가 행을 늘린다 (MD-14).
        if block == .tableRow {
            return handleTableNewline(lineRange: lineRange, textStorage: textStorage, textView: textView)
        }

        // ``` 만 친 줄에서 엔터 → 코드 박스로 연다 (MD-10).
        if block == .paragraph, openCodeBlockIfFenceOnly(lineRange: lineRange, textStorage: textStorage, textView: textView) {
            return true
        }

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

    /// 줄에 ```` ``` ````만 있으면 그 줄을 코드 박스로 바꾼다.
    ///
    /// 규칙(InputRule)으로 처리하지 않는 이유는 입력이 끝나는 신호가 공백이 아니라 엔터이기 때문이다.
    /// 공백까지 친 경우는 `CodeBlockRule`이 받는다 — 두 길이 같은 결과로 이어진다.
    private func openCodeBlockIfFenceOnly(
        lineRange: NSRange,
        textStorage: NSTextStorage,
        textView: MemoTextView
    ) -> Bool {
        let text = textStorage.string as NSString
        let hasNewline = text.substring(with: lineRange).hasSuffix("\n")
        let contentRange = NSRange(
            location: lineRange.location,
            length: lineRange.length - (hasNewline ? 1 : 0)
        )
        let line = text.substring(with: contentRange).trimmingCharacters(in: .whitespaces)
        guard line == MarkdownParser.codeFence else { return false }
        guard textView.shouldChangeText(in: contentRange, replacementString: "") else { return false }

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: contentRange, with: "")
        applyBlockAttributes(.codeBlock, lineStart: lineRange.location, textStorage: textStorage)
        textStorage.endEditing()

        textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
        textView.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha, block: .codeBlock)
        textView.didChangeText()
        return true
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

        // 중간에 항목을 끼워 넣었을 수도 있다. 덩어리 전체를 다시 센다 (MD-03).
        if case .ordered = nextBlock {
            renumberOrderedList(touching: caret.location, textStorage: textStorage, textView: textView)
        }
        textView.didChangeText()
        return true
    }

    /// Tab / Shift+Tab (KEY-08).
    public func handleIndent(deeper: Bool) -> Bool {
        // 표 안에서는 단계가 아니라 칸을 옮긴다 (MD-14).
        if let textView, let textStorage = textView.textStorage {
            let text = textStorage.string as NSString
            let caret = textView.selectedRange()
            let lineRange = text.lineRange(for: NSRange(location: min(caret.location, text.length), length: 0))
            if blockStyle(in: textStorage, at: lineRange.location) == .tableRow {
                return moveBetweenTableCells(forward: deeper)
            }
        }
        return changeIndent(by: deeper ? 1 : -1)
    }

    private func changeIndent(by delta: Int) -> Bool {
        guard let textView, let textStorage = textView.textStorage else { return false }
        guard !textView.isComposingText else { return false }

        let text = textStorage.string as NSString
        let caret = textView.selectedRange()
        guard caret.location <= text.length else { return false }

        let lineRange = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let block = blockStyle(in: textStorage, at: lineRange.location)
        // 코드 박스 안의 Tab은 들여쓰기가 아니라 코드의 일부다.
        guard block.allowsIndentChange else { return false }

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

        // 단계가 바뀌면 번호를 다시 매긴다. 단계마다 번호는 따로 세어야 한다 (MD-03).
        renumberOrderedList(touching: lineRange.location, textStorage: textStorage, textView: textView)
        textView.didChangeText()
        return true
    }

    // MARK: - 번호 다시 매기기 (MD-03)

    /// 커서가 속한 목록 덩어리의 번호를 처음부터 다시 센다.
    ///
    /// 단계를 내리면 그 단계에서 새로 1번부터 시작해야 한다.
    /// 윗 단계의 번호를 그대로 물려받으면 `1. / b.`처럼 이어지지 않는 번호가 남는다.
    /// 단계를 올릴 때도 마찬가지로, 그 단계의 이전 항목을 이어받아야 한다.
    ///
    /// 세는 방법은 단계별 counter 하나다. 더 깊은 단계는 얕은 단계를 만나는 순간 지운다 —
    /// 그래야 목록이 위로 올라왔다가 다시 내려갈 때 새 번호로 시작한다.
    public func renumberOrderedList(touching lineLocation: Int, textStorage: NSTextStorage, textView: MemoTextView) {
        var location = listBlockStart(from: lineLocation, textStorage: textStorage)
        var counters: [Int: Int] = [:]
        var caret = textView.selectedRange()

        textStorage.beginEditing()
        defer {
            textStorage.endEditing()
            let length = (textStorage.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(caret.location, length), length: 0))
        }

        while location < (textStorage.string as NSString).length {
            let text = textStorage.string as NSString
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let block = blockStyle(in: textStorage, at: lineRange.location)
            guard block.allowsIndentChange else { return }

            let indent = block.indent
            // 얕은 단계로 돌아왔으면 그보다 깊은 셈은 버린다.
            for level in counters.keys where level > indent {
                counters[level] = nil
            }

            var lengthShift = 0
            if case .ordered(_, let current) = block {
                let expected = (counters[indent] ?? 0) + 1
                counters[indent] = expected

                if current != expected {
                    let newBlock = BlockStyle.ordered(indent: indent, number: expected)
                    let oldPrefix = AttributedTextBridge.visiblePrefix(for: block)
                    let newPrefix = AttributedTextBridge.visiblePrefix(for: newBlock)
                    let prefixRange = NSRange(
                        location: lineRange.location,
                        length: min((oldPrefix as NSString).length, lineRange.length)
                    )
                    textStorage.replaceCharacters(in: prefixRange, with: newPrefix)
                    applyBlockAttributes(newBlock, lineStart: lineRange.location, textStorage: textStorage)

                    lengthShift = (newPrefix as NSString).length - prefixRange.length
                    if caret.location > lineRange.location {
                        caret.location = max(lineRange.location, caret.location + lengthShift)
                    }
                }
            }

            let nextLocation = NSMaxRange(lineRange) + lengthShift
            guard nextLocation > location else { return }
            location = nextLocation
        }
    }

    /// 이 줄이 속한 목록 덩어리의 첫 줄. 목록이 아닌 줄을 만나면 거기서 멈춘다.
    private func listBlockStart(from lineLocation: Int, textStorage: NSTextStorage) -> Int {
        let text = textStorage.string as NSString
        var start = text.lineRange(for: NSRange(location: min(lineLocation, text.length), length: 0)).location

        while start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            guard blockStyle(in: textStorage, at: previous.location).allowsIndentChange else { break }
            start = previous.location
        }
        return start
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
    ///
    /// 코드 박스도 여기 든다. 코드는 여러 줄이 모여 하나이므로,
    /// 엔터마다 상자를 빠져나오면 쓸 수가 없다. 빈 줄에서 한 번 더 치면 빠져나온다.
    var continuesOnNewline: Bool {
        switch self {
        case .bullet, .ordered, .checkbox, .codeBlock: return true
        default: return false
        }
    }

    /// 이어질 다음 항목. 번호는 하나 올라가고, 체크박스는 체크가 풀린 상태로 시작한다.
    var nextItem: BlockStyle {
        switch self {
        case .bullet(let indent): return .bullet(indent: indent)
        case .ordered(let indent, let number): return .ordered(indent: indent, number: number + 1)
        case .checkbox(let indent, _): return .checkbox(indent: indent, checked: false)
        case .codeBlock: return .codeBlock
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
