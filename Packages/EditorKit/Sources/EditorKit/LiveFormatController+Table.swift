import AppKit
import MarkdownEngine

/// 표를 다루는 동작들 (MD-14).
///
/// 표는 여러 줄이 모여 하나이므로, 한 줄짜리 서식과 달리 넣는 것부터 다르다.
/// 넣고 나서도 칸 사이를 오가고 행을 늘릴 수 있어야 실제로 쓸 수 있다 —
/// 목록에 엔터·Tab 동작이 필요한 것과 같은 이유다.
extension LiveFormatController {
    /// 커서 자리에 표를 넣는다. 슬래시 명령과 서식 막대 버튼이 같은 길을 쓴다.
    public func insertTable(columns: Int = 2, rows: Int = 3) {
        guard let textView, let textStorage = textView.textStorage else { return }

        let text = textStorage.string as NSString
        let caret = textView.selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: min(caret.location, text.length), length: 0))
        let hasNewline = text.substring(with: lineRange).hasSuffix("\n")
        let contentRange = NSRange(
            location: lineRange.location,
            length: lineRange.length - (hasNewline ? 1 : 0)
        )
        let currentLine = text.substring(with: contentRange).trimmingCharacters(in: .whitespaces)

        // 빈 줄이면 그 자리에 놓고, 쓰던 줄이면 아래에 새로 만든다.
        let skeleton = MarkdownTable.skeleton(columns: columns, rows: rows)
        let replaceRange = currentLine.isEmpty
            ? contentRange
            : NSRange(location: NSMaxRange(contentRange), length: 0)
        let body = skeleton.joined(separator: "\n")
        let insertion = currentLine.isEmpty ? body : "\n" + body

        guard textView.shouldChangeText(in: replaceRange, replacementString: insertion) else { return }

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: replaceRange, with: insertion)

        // 줄마다 표 서식을 입힌다. 첫 줄이 어디서 시작하는지부터 다시 센다.
        var lineStart = replaceRange.location + (currentLine.isEmpty ? 0 : 1)
        for line in skeleton {
            applyBlockAttributes(.tableRow, lineStart: lineStart, textStorage: textStorage)
            lineStart += (line as NSString).length + 1
        }
        textStorage.endEditing()

        // 첫 칸의 안내 글자를 고른 채로 둔다.
        // 커서만 앞에 두면 이어 친 글자가 안내 글자 앞에 붙어 "월항목"처럼 된다.
        let firstRowStart = replaceRange.location + (currentLine.isEmpty ? 0 : 1)
        let firstCell = MarkdownTable.cells(of: skeleton[0]).first?.trimmingCharacters(in: .whitespaces) ?? ""
        textView.setSelectedRange(NSRange(location: firstRowStart + 2, length: (firstCell as NSString).length))
        textView.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha, block: .tableRow)
        textView.didChangeText()
    }

    /// Tab / Shift+Tab — 칸 사이를 오간다. 마지막 칸에서 Tab을 누르면 행이 하나 늘어난다.
    func moveBetweenTableCells(forward: Bool) -> Bool {
        guard let textView, let textStorage = textView.textStorage else { return false }
        guard !textView.isComposingText else { return false }

        let text = textStorage.string as NSString
        let caret = textView.selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: min(caret.location, text.length), length: 0))

        if forward {
            // 커서 뒤의 다음 세로줄을 찾는다. 그 뒤가 다음 칸이다.
            let searchStart = min(caret.location, NSMaxRange(lineRange))
            let tail = NSRange(location: searchStart, length: max(0, NSMaxRange(lineRange) - searchStart))
            let pipe = text.range(of: "|", options: [], range: tail)

            if pipe.location != NSNotFound, isCellStart(after: pipe.location, lineRange: lineRange, text: text) {
                textView.setSelectedRange(NSRange(location: caretPosition(afterPipeAt: pipe.location, text: text), length: 0))
                return true
            }
            // 줄 끝이면 다음 행으로. 다음 행이 없으면 새로 만든다.
            if let nextRow = nextTableLine(after: lineRange, textStorage: textStorage) {
                textView.setSelectedRange(NSRange(location: nextRow.location + 2, length: 0))
                return true
            }
            return appendTableRow(after: lineRange, textStorage: textStorage, textView: textView)
        }

        // 뒤로 갈 때는 커서 앞의 세로줄 두 개 사이가 이전 칸이다.
        let head = NSRange(location: lineRange.location, length: max(0, caret.location - lineRange.location))
        let previous = text.range(of: "|", options: .backwards, range: head)

        if previous.location != NSNotFound {
            let beforeThat = text.range(
                of: "|",
                options: .backwards,
                range: NSRange(location: lineRange.location, length: previous.location - lineRange.location)
            )
            if beforeThat.location != NSNotFound {
                textView.setSelectedRange(
                    NSRange(location: caretPosition(afterPipeAt: beforeThat.location, text: text), length: 0)
                )
                return true
            }
        }

        // 첫 칸이었다면 윗 행의 마지막 칸으로 올라간다. 없으면 그 자리에 머문다.
        guard let above = previousTableLine(before: lineRange, textStorage: textStorage),
              let position = lastCellPosition(in: above, text: text)
        else { return true }
        textView.setSelectedRange(NSRange(location: position, length: 0))
        return true
    }

    /// 그 줄의 마지막 칸이 시작하는 자리.
    private func lastCellPosition(in lineRange: NSRange, text: NSString) -> Int? {
        let hasNewline = text.substring(with: lineRange).hasSuffix("\n")
        let contentRange = NSRange(
            location: lineRange.location,
            length: lineRange.length - (hasNewline ? 1 : 0)
        )
        // 줄 끝의 닫는 세로줄, 그리고 그 앞의 세로줄 사이가 마지막 칸이다.
        let closing = text.range(of: "|", options: .backwards, range: contentRange)
        guard closing.location != NSNotFound else { return nil }
        let opening = text.range(
            of: "|",
            options: .backwards,
            range: NSRange(location: contentRange.location, length: closing.location - contentRange.location)
        )
        guard opening.location != NSNotFound else { return nil }
        return caretPosition(afterPipeAt: opening.location, text: text)
    }

    /// 엔터 — 아래에 빈 행을 만든다. 빈 행에서 다시 치면 표를 빠져나온다.
    func handleTableNewline(lineRange: NSRange, textStorage: NSTextStorage, textView: MemoTextView) -> Bool {
        let text = textStorage.string as NSString
        let hasNewline = text.substring(with: lineRange).hasSuffix("\n")
        let contentRange = NSRange(
            location: lineRange.location,
            length: lineRange.length - (hasNewline ? 1 : 0)
        )
        let line = text.substring(with: contentRange)

        // 빈 행에서 엔터 → 그 행을 지우고 표 밖으로 나간다.
        if MarkdownTable.isEmptyRow(line) {
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

        return appendTableRow(after: lineRange, textStorage: textStorage, textView: textView)
    }

    // MARK: - 세부 구현

    /// 이 줄 아래에 같은 칸 수의 빈 행을 만들고 커서를 첫 칸에 둔다.
    @discardableResult
    private func appendTableRow(
        after lineRange: NSRange,
        textStorage: NSTextStorage,
        textView: MemoTextView
    ) -> Bool {
        let text = textStorage.string as NSString
        let hasNewline = text.substring(with: lineRange).hasSuffix("\n")
        let contentRange = NSRange(
            location: lineRange.location,
            length: lineRange.length - (hasNewline ? 1 : 0)
        )
        let columns = MarkdownTable.columnCount(of: text.substring(with: contentRange))
        let insertion = "\n" + MarkdownTable.emptyRow(columns: columns)
        let insertAt = NSRange(location: NSMaxRange(contentRange), length: 0)

        guard textView.shouldChangeText(in: insertAt, replacementString: insertion) else { return false }

        beginFormatting()
        defer { endFormatting() }

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: insertAt, with: insertion)
        applyBlockAttributes(.tableRow, lineStart: insertAt.location + 1, textStorage: textStorage)
        textStorage.endEditing()

        textView.setSelectedRange(NSRange(location: insertAt.location + 3, length: 0))
        textView.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha, block: .tableRow)
        textView.didChangeText()
        return true
    }

    /// 세로줄 바로 뒤의 빈칸 하나까지 건너뛴 자리. 칸의 첫 글자 자리다.
    private func caretPosition(afterPipeAt location: Int, text: NSString) -> Int {
        let next = location + 1
        guard next < text.length else { return next }
        return text.substring(with: NSRange(location: next, length: 1)) == " " ? next + 1 : next
    }

    /// 그 세로줄 뒤에 칸이 더 있는가. 줄 끝의 닫는 세로줄이면 없다.
    private func isCellStart(after pipeLocation: Int, lineRange: NSRange, text: NSString) -> Bool {
        let rest = NSRange(
            location: pipeLocation + 1,
            length: max(0, NSMaxRange(lineRange) - pipeLocation - 1)
        )
        guard rest.length > 0 else { return false }
        let tail = text.substring(with: rest).trimmingCharacters(in: .whitespacesAndNewlines)
        return !tail.isEmpty
    }

    private func nextTableLine(after lineRange: NSRange, textStorage: NSTextStorage) -> NSRange? {
        let text = textStorage.string as NSString
        let next = NSMaxRange(lineRange)
        guard next < text.length else { return nil }
        let candidate = text.lineRange(for: NSRange(location: next, length: 0))
        guard blockStyle(in: textStorage, at: candidate.location) == .tableRow else { return nil }
        return candidate
    }

    private func previousTableLine(before lineRange: NSRange, textStorage: NSTextStorage) -> NSRange? {
        guard lineRange.location > 0 else { return nil }
        let text = textStorage.string as NSString
        let candidate = text.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
        guard blockStyle(in: textStorage, at: candidate.location) == .tableRow else { return nil }
        return candidate
    }
}
