import AppKit
import MarkdownEngine

/// 붙여넣기 — 다른 앱(노션 등)에서 복사한 마크다운을 서식으로 바꿔 넣는다.
///
/// 입력 중 변환은 커서가 있는 줄에만, 글자를 칠 때 일어난다. 여러 줄을 한 번에 붙여 넣으면
/// 어느 줄도 변환되지 않아 `# ` · `- [ ] ` · `**` 같은 기호가 글자로 남았다.
/// 붙여 넣는 순간 전체를 마크다운으로 해석해, 파일을 열 때와 같은 모양으로 넣는다.
extension LiveFormatController {
    /// 처리했으면 true. 서식이 없는 한 줄짜리 글은 false를 돌려 기본 붙여넣기에 맡긴다 —
    /// 그래야 제목 줄에 낱말을 붙여 넣으면 그대로 제목 글자가 된다.
    func pasteMarkdown(_ text: String) -> Bool {
        guard let textView, let textStorage = textView.textStorage else { return false }

        let lines = PastedMarkdown.parse(text)
        guard let first = lines.first else { return false }
        let isPlainWords = lines.count == 1 && first.block == .paragraph
            && first.spans.allSatisfy { $0.styles.isEmpty && $0.textColor == nil }
        if isPlainWords { return false }

        let text = textStorage.string as NSString
        let selection = textView.selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let hasNewline = lineRange.length > 0 && text.substring(with: lineRange).hasSuffix("\n")
        let lineEnd = NSMaxRange(lineRange) - (hasNewline ? 1 : 0)
        let currentBlock = blockStyle(in: textStorage, at: lineRange.location)
        let currentPrefix = (AttributedTextBridge.visiblePrefix(for: currentBlock) as NSString).length
        let contentStart = min(lineRange.location + currentPrefix, lineEnd)

        // 커서 줄에 붙여 넣는 글 말고는 아무것도 없는가. 그렇다면 첫 줄은 붙여 넣는 줄의 블록을 따른다.
        let lineIsBlank = selection.location <= contentStart && NSMaxRange(selection) >= lineEnd

        let result = NSMutableAttributedString()
        var lineStarts: [(offset: Int, block: BlockStyle)] = []
        var replaceRange = selection

        for (index, line) in lines.enumerated() {
            if index == 0 {
                if lineIsBlank && (line.block != .paragraph || currentBlock == .paragraph) {
                    // 빈 줄(또는 표식만 있는 줄)을 붙여 넣는 줄로 통째로 바꾼다.
                    replaceRange = NSRange(location: lineRange.location, length: max(0, lineEnd - lineRange.location))
                    lineStarts.append((0, line.block))
                    result.append(fullLine(line))
                } else {
                    // 글이 있는 줄 가운데에 넣는다 — 그 줄의 블록을 지키고 글자 서식만 가져온다.
                    result.append(merged(line, into: currentBlock))
                }
            } else {
                result.append(NSAttributedString(string: "\n"))
                lineStarts.append((result.length, line.block))
                result.append(fullLine(line))
            }
        }

        guard textView.shouldChangeText(in: replaceRange, replacementString: result.string) else { return true }
        beginFormatting()
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: replaceRange, with: result)
        // 체크된 항목은 취소선과 흐린 색으로 (CHK-02). 파일을 열 때와 같은 모양이어야 한다.
        for start in lineStarts {
            applyCheckedAppearance(start.block, lineStart: replaceRange.location + start.offset, textStorage: textStorage)
        }
        textStorage.endEditing()
        endFormatting()

        textView.setSelectedRange(NSRange(location: replaceRange.location + result.length, length: 0))
        textView.resetTypingAttributes(
            theme: currentTheme,
            textAlpha: currentTextAlpha,
            block: lines.count > 1 ? (lines.last?.block ?? .paragraph) : currentBlock
        )
        textView.didChangeText()
        return true
    }

    /// 표식(`• `, `☐ ` …)까지 붙은 온전한 한 줄.
    private func fullLine(_ line: StyledLine) -> NSAttributedString {
        AttributedTextBridge.attributedString(from: line, theme: currentTheme, textAlpha: currentTextAlpha)
    }

    /// 다른 블록의 줄 가운데에 들어갈 글자. 그 블록의 글꼴로 그리되 표식은 뺀다.
    private func merged(_ line: StyledLine, into block: BlockStyle) -> NSAttributedString {
        let rendered = AttributedTextBridge.attributedString(
            from: StyledLine(block: block, spans: line.spans),
            theme: currentTheme,
            textAlpha: currentTextAlpha
        )
        let prefix = (AttributedTextBridge.visiblePrefix(for: block) as NSString).length
        guard rendered.length >= prefix else { return rendered }
        return rendered.attributedSubstring(from: NSRange(location: prefix, length: rendered.length - prefix))
    }
}
