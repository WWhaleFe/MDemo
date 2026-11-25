import AppKit
import MarkdownEngine
import MemoCore
import UniformTypeIdentifiers

/// 이미지 넣기 (IMG-01).
///
/// 붙여넣기 · 끌어 놓기 · "이미지 넣기" 단추가 모두 이 길로 모인다.
/// 파일은 첨부 폴더에 저장하고(큰 이미지는 줄여서, IMG-06), 본문에는 한 줄만 넣는다.
extension LiveFormatController {
    /// 이미지 저장을 요청하고 완료 뒤 커서 자리에 넣는다. 요청을 받았으면 true.
    func insertImages(from urls: [URL]) -> Bool {
        guard !urls.isEmpty, let store = textView?.imageStore else { return false }
        textView?.commitComposition()
        return enqueueImageSave(store: store) {
            urls.compactMap { url in
                guard let image = try? AttachmentImages.save(imageFileAt: url, into: store.directory) else { return nil }
                return (image, url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    /// 클립보드 이미지 데이터(스크린샷 등)를 커서 자리에 넣는다.
    func insertImage(data: Data, alt: String = "", width: Int? = nil) -> Bool {
        guard !data.isEmpty, let store = textView?.imageStore else { return false }
        textView?.commitComposition()
        return enqueueImageSave(store: store, width: width) {
            guard let image = try? AttachmentImages.save(imageData: data, into: store.directory) else { return [] }
            return [(image, alt)]
        }
    }

    /// 파일 읽기와 인코딩은 백그라운드에서 하고 줄 삽입은 메인에서 요청 순서대로 한다.
    private func enqueueImageSave(
        store: MemoImageStore,
        width: Int? = nil,
        save: @escaping @Sendable () -> [(SavedAttachment, String)]
    ) -> Bool {
        let previous = pendingImageInsertion
        pendingImageInsertion = Task { @MainActor [weak self] in
            await previous?.value
            let saved = await Task.detached(priority: .userInitiated, operation: save).value
            guard let self, self.textView?.imageStore === store else { return }
            _ = self.insertImageLines(saved, width: width)
        }
        return true
    }

    /// 파일 선택 창을 열어 고른 이미지를 넣는다. 서식 막대의 "이미지 넣기" 단추가 부른다.
    public func chooseAndInsertImages() {
        guard textView?.imageStore != nil else { return }
        textView?.commitComposition()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "메모에 넣을 이미지를 고르세요"
        // 메모 창은 떠 있는 창이라 패널이 뒤에 숨지 않도록 앱을 앞으로 가져온다.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.insertImages(from: urls)
                self.textView?.window?.makeFirstResponder(self.textView)
            }
        }
    }

    /// 커서 줄 아래(줄 가운데면 쪼개서)에 이미지 줄을 넣는다. 항상 새 줄이다.
    private func insertImageLines(_ images: [(SavedAttachment, String)], width: Int? = nil) -> Bool {
        guard !images.isEmpty, let textView, let textStorage = textView.textStorage else { return false }

        textView.commitComposition()
        let text = textStorage.string as NSString
        var selection = textView.selectedRange()
        if let index = textView.selectedImageIndex {
            // 고른 이미지 위에서는 이미지를 지우지 않고 그 뒤에 넣는다.
            selection = NSRange(location: index + 1, length: 0)
        }
        guard NSMaxRange(selection) <= text.length else { return false }

        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let hasNewline = lineRange.length > 0 && text.character(at: NSMaxRange(lineRange) - 1) == 0x0A
        let lineStart = lineRange.location
        let lineEnd = NSMaxRange(lineRange) - (hasNewline ? 1 : 0)
        let isBlank = lineStart == lineEnd
        let isAtStart = selection.location == lineStart

        func newline() -> NSAttributedString {
            NSAttributedString(string: "\n", attributes: [
                .font: currentTheme.font(for: .paragraph),
                .foregroundColor: currentTheme.textColor.withAlphaComponent(currentTextAlpha),
                .memoBlockStyle: BlockStyleBox(.paragraph),
            ])
        }

        let result = NSMutableAttributedString()
        // 글이 있는 줄 가운데나 끝이면 앞쪽을 두고 새 줄을 연다.
        if !isBlank, !isAtStart { result.append(newline()) }
        for (index, entry) in images.enumerated() {
            if index > 0 { result.append(newline()) }
            let reference = MarkdownImage(alt: entry.1, path: entry.0.relativePath, width: width)
            result.append(AttributedTextBridge.imageLine(reference, theme: currentTheme, textAlpha: currentTextAlpha))
        }

        // 이미지 줄 다음에는 커서가 올 새 줄이 있어야 한다.
        // 빈 줄이거나 줄 끝인데 이미 줄바꿈이 뒤따르면 그것을 쓰고, 아니면 새로 만든다.
        let reusesExistingNewline = NSMaxRange(selection) == lineEnd && hasNewline
        if !reusesExistingNewline { result.append(newline()) }

        let caret = selection.location + result.length + (reusesExistingNewline ? 1 : 0)
        textView.replaceRangeUndoably(
            selection, with: result, actionName: "이미지 넣기",
            selectionAfter: NSRange(location: caret, length: 0)
        )
        textView.resetTypingAttributes(theme: currentTheme, textAlpha: currentTextAlpha)
        return true
    }
}
