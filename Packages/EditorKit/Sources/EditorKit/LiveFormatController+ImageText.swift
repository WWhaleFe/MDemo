import AppKit
import MarkdownEngine

/// 이미지 글자 읽기(OCR) 결과를 본문에 넣는 요청.
///
/// 이미지 우클릭 메뉴가 만들고, 인식과 미리보기 시트는 창 계층이 맡는다.
/// 시트가 열려 있는 동안 본문이 바뀔 수 있어서, 위치(글자 번호)가 아니라 첨부 객체로 이미지를 다시 찾는다.
public struct ImageTextRequest {
    public let fileURL: URL
    /// true면 글을 넣은 뒤 이미지 줄을 지운다. false면 이미지 줄 바로 아래에 넣는다.
    public let replacesImage: Bool
    /// 시트에 보여 줄 원본 썸네일.
    public let thumbnail: NSImage?
    let attachment: MemoImageAttachment

    init(fileURL: URL, replacesImage: Bool, thumbnail: NSImage?, attachment: MemoImageAttachment) {
        self.fileURL = fileURL
        self.replacesImage = replacesImage
        self.thumbnail = thumbnail
        self.attachment = attachment
    }
}

extension LiveFormatController {
    /// 글자 읽기 결과를 이미지 줄 아래에 넣거나(이미지는 그대로), 이미지 줄을 글로 바꾼다.
    ///
    /// 되돌리기는 한 번에 전부 돌아가도록 `replaceRangeUndoably` 한 번으로 처리한다.
    /// 넣은 줄은 붙여넣기와 같은 길로 서식(제목·목록·체크)을 입힌다. 넣었으면 true.
    @discardableResult
    public func applyImageText(_ text: String, isPlain: Bool, for request: ImageTextRequest) -> Bool {
        guard let textView, let textStorage = textView.textStorage else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 이미지 줄을 다시 찾는다. 그사이 지워졌으면 넣지 않는다.
        var imageIndex: Int?
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, stop in
            if (value as? MemoImageAttachment) === request.attachment {
                imageIndex = range.location
                stop.pointee = true
            }
        }
        guard let imageIndex else { return false }

        let lines: [StyledLine] = isPlain
            ? trimmed.components(separatedBy: "\n").map { StyledLine(block: .paragraph, text: $0) }
            : PastedMarkdown.parse(trimmed)
        guard !lines.isEmpty else { return false }

        var starts: [(offset: Int, block: BlockStyle)] = []
        let body = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { body.append(newlineAttributed()) }
            starts.append((body.length, line.block))
            body.append(AttributedTextBridge.attributedString(from: line, theme: currentTheme, textAlpha: currentTextAlpha))
        }

        let string = textStorage.string as NSString
        let lineRange = string.lineRange(for: NSRange(location: imageIndex, length: 0))
        let hasNewline = lineRange.length > 0 && string.character(at: NSMaxRange(lineRange) - 1) == 0x0A
        let contentEnd = NSMaxRange(lineRange) - (hasNewline ? 1 : 0)

        let replaceRange: NSRange
        let inserted = NSMutableAttributedString()
        var bodyOffset = 0
        if request.replacesImage {
            // 이미지 줄의 내용만 글로 바꾼다. 줄바꿈은 그대로 둔다.
            replaceRange = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            inserted.append(body)
        } else if hasNewline {
            replaceRange = NSRange(location: NSMaxRange(lineRange), length: 0)
            inserted.append(body)
            // 뒤에 줄이 이어지면 줄바꿈으로 갈라 준다. 문서 맨 끝이면 그대로 둔다.
            if replaceRange.location < string.length { inserted.append(newlineAttributed()) }
        } else {
            replaceRange = NSRange(location: string.length, length: 0)
            inserted.append(newlineAttributed())
            bodyOffset = 1
            inserted.append(body)
        }

        textView.replaceRangeUndoably(
            replaceRange, with: inserted, actionName: request.replacesImage ? "글자로 바꾸기" : "글자 읽어 넣기",
            selectionAfter: NSRange(location: replaceRange.location + inserted.length, length: 0)
        )
        // 체크된 항목은 취소선과 흐린 색으로 (CHK-02).
        for start in starts {
            applyCheckedAppearance(
                start.block, lineStart: replaceRange.location + bodyOffset + start.offset, textStorage: textStorage
            )
        }
        textView.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha, block: lines.last?.block ?? .paragraph)
        return true
    }

    private func newlineAttributed() -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [
            .font: currentTheme.font(for: .paragraph),
            .foregroundColor: currentTheme.textColor.withAlphaComponent(currentTextAlpha),
            .memoBlockStyle: BlockStyleBox(.paragraph),
        ])
    }

    /// AirDrop으로 받은 사진을 커서 자리에 넣는다. 이 편집기에 커서가 없으면 끝에 넣는다.
    @discardableResult
    public func insertReceivedImages(_ urls: [URL]) -> Bool {
        guard let textView, let textStorage = textView.textStorage else { return false }
        if textView.window?.firstResponder !== textView {
            textView.setSelectedRange(NSRange(location: textStorage.length, length: 0))
        }
        return insertImages(from: urls)
    }
}
