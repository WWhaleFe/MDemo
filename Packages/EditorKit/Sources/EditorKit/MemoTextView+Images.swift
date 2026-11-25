import AppKit
import MarkdownEngine
import MemoCore
import UniformTypeIdentifiers

/// 본문 이미지의 고르기 · 크기 조절 · 우클릭 메뉴 · 붙여넣기 · 끌어 놓기 (IMG-01, IMG-03, IMG-04).
///
/// 이미지는 줄 하나에 첨부 글자 하나로 들어 있다 (`MemoImageAttachment`).
/// 이미지를 고른다는 것은 그 글자 하나를 선택 범위로 잡는다는 뜻이다.
/// 되돌리기는 NSTextView 기본 기능에 맡기지 않고 직접 등록한다 -
/// 서식 없는 모드의 기본 되돌리기는 첨부 속성을 되살리지 못할 수 있기 때문이다.
/// 메모끼리 복사할 때 외부 앱용 이미지 데이터에 설명과 표시 너비를 더한다.
struct MemoImageClipboard: Codable {
    let data: Data
    let alt: String
    let width: Int?
    static let pasteboardType = NSPasteboard.PasteboardType("com.bkc.memo.inline-image")
}

extension MemoTextView {
    // MARK: - 고르기

    /// 지금 고른 이미지의 글자 위치. 이미지가 아니면 nil.
    public var selectedImageIndex: Int? {
        let range = selectedRange()
        guard range.length == 1, imageAttachment(at: range.location) != nil else { return nil }
        return range.location
    }

    func imageAttachment(at index: Int) -> MemoImageAttachment? {
        guard let textStorage, index >= 0, index < textStorage.length else { return nil }
        return textStorage.attribute(.attachment, at: index, effectiveRange: nil) as? MemoImageAttachment
    }

    /// 이미지가 차지한 영역 (뷰 좌표).
    func imageRect(at index: Int) -> NSRect? {
        guard let manager = layoutManager as? MemoLayoutManager,
              let rect = manager.attachmentRect(forCharacterIndex: index) else { return nil }
        let origin = textContainerOrigin
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// 지점 아래의 이미지 글자 위치.
    func imageIndex(at point: NSPoint) -> Int? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        let nearest = characterIndexForInsertion(at: point)
        for index in [nearest, nearest - 1] {
            if let rect = imageRect(at: index), rect.contains(point) { return index }
        }
        return nil
    }

    /// 줄 폭 안에서 이미지가 가질 수 있는 가장 큰 너비.
    func availableImageWidth() -> CGFloat {
        guard let container = textContainer else { return 400 }
        let width = container.widthTracksTextView ? container.size.width : bounds.width - textContainerInset.width * 2
        return max(MemoImageAttachment.minimumWidth, min(4096, width - container.lineFragmentPadding * 2))
    }

    public override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        let before = selectedImageIndex
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        // 테두리와 손잡이는 선택이 바뀔 때 다시 그려야 한다.
        let after = selectedImageIndex
        guard before != after, let layoutManager, let length = textStorage?.length else { return }
        for index in [before, after].compactMap({ $0 }) where index < length {
            layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: index, length: 1))
        }
    }

    /// 이미지를 눌렀을 때의 처리. 처리했으면 true.
    func handleImageMouseDown(_ event: NSEvent, at point: NSPoint) -> Bool {
        commitComposition()

        // 이미 고른 이미지의 손잡이를 누르면 크기 조절이다.
        if let index = selectedImageIndex, let rect = imageRect(at: index),
           let handle = MemoImageHandle.rects(in: rect).first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }) {
            window?.makeFirstResponder(self)
            trackImageResize(index: index, corner: handle.corner, startPoint: point)
            return true
        }
        if let index = imageIndex(at: point) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: index, length: 1))
            return true
        }
        return false
    }

    // MARK: - 크기 조절 (IMG-03)

    /// 모서리를 끄는 동안 너비를 바꾼다. 비율은 너비로 정해지므로 늘 고정이다.
    private func trackImageResize(index: Int, corner: MemoImageHandle.Corner, startPoint: NSPoint) {
        guard let attachment = imageAttachment(at: index), let startRect = imageRect(at: index) else { return }
        breakUndoCoalescing()
        let thumbnail = imageStore?.thumbnail(of: attachment.reference.fileName, displayWidth: startRect.width, scale: window?.backingScaleFactor ?? 2)
        attachment.beginResizing(thumbnail: thumbnail)
        defer {
            attachment.endResizing()
            layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: index, length: 1))
        }
        let originalWidth = attachment.reference.width
        let startWidth = startRect.width
        let direction: CGFloat = corner.growsToTheRight ? 1 : -1
        let limit = max(MemoImageAttachment.minimumWidth, availableImageWidth())
        var latest = Int(startWidth.rounded())
        var moved = false

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            let width = min(max(MemoImageAttachment.minimumWidth, startWidth + direction * (point.x - startPoint.x)), limit)
            latest = Int(width.rounded())
            if next.type == .leftMouseUp { break }
            if latest != Int(startWidth.rounded()) { moved = true }
            applyImageWidth(latest, at: index)
        }
        guard moved || latest != Int(startWidth.rounded()) else {
            applyImageWidth(originalWidth, at: index)
            return
        }
        // 끄는 동안 바뀐 값을 원래대로 돌린 뒤, 한 번의 되돌릴 수 있는 변경으로 확정한다.
        applyImageWidth(originalWidth, at: index)
        setImageWidth(latest, at: index, actionName: "이미지 크기")
    }

    /// 화면과 본문 속성만 바꾼다. 되돌리기는 등록하지 않는다.
    private func applyImageWidth(_ width: Int?, at index: Int) {
        guard let attachment = imageAttachment(at: index), let textStorage else { return }
        attachment.reference.width = width.map { max(1, $0) }
        let range = NSRange(location: index, length: 1)
        textStorage.addAttribute(.memoBlockStyle, value: BlockStyleBox(.image(attachment.reference)), range: range)
        layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager?.invalidateDisplay(forCharacterRange: range)
        needsDisplay = true
    }

    /// 너비를 바꾸고 되돌리기를 등록한다. nil이면 줄 폭에 맞춘다.
    public func setImageWidth(_ width: Int?, at index: Int, actionName: String = "이미지 크기") {
        guard let attachment = imageAttachment(at: index) else { return }
        let old = attachment.reference.width
        guard old != width else { return }
        breakUndoCoalescing()
        applyImageWidth(width, at: index)
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setImageWidth(old, at: index, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
        didChangeText()
    }

    // MARK: - 줄 바꾸기 (되돌리기 포함)

    private final class EditBox: @unchecked Sendable {
        let value: NSAttributedString
        init(_ value: NSAttributedString) { self.value = value }
    }

    /// `range`를 `replacement`로 바꾸고, 같은 자리를 이전 내용으로 되돌리는 동작을 등록한다.
    func replaceRangeUndoably(
        _ range: NSRange,
        with replacement: NSAttributedString,
        actionName: String,
        selectionAfter: NSRange? = nil
    ) {
        guard let textStorage, NSMaxRange(range) <= textStorage.length else { return }
        breakUndoCoalescing()
        let old = EditBox(textStorage.attributedSubstring(from: range))
        let inserted = NSRange(location: range.location, length: replacement.length)
        textStorage.replaceCharacters(in: range, with: replacement)
        if let selectionAfter { setSelectedRange(selectionAfter) }

        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.replaceRangeUndoably(
                    inserted, with: old.value, actionName: actionName,
                    selectionAfter: NSRange(location: range.location + old.value.length, length: 0)
                )
            }
        }
        undoManager?.setActionName(actionName)
        didChangeText()
    }

    /// 이미지 줄을 지운다. 줄에 다른 글이 섞여 있으면 이미지 글자만 지운다.
    public func deleteImageLine(at index: Int) {
        guard let textStorage, imageAttachment(at: index) != nil else { return }
        let text = textStorage.string as NSString
        let line = text.lineRange(for: NSRange(location: index, length: 0))
        let hasNewline = line.length > 0 && text.character(at: NSMaxRange(line) - 1) == 0x0A
        let contentLength = line.length - (hasNewline ? 1 : 0)

        var range = NSRange(location: index, length: 1)
        if contentLength == 1 {
            range = line
            // 마지막 줄이면 앞 줄의 줄바꿈까지 지워 빈 줄이 남지 않게 한다.
            if !hasNewline, line.location > 0 {
                range = NSRange(location: line.location - 1, length: line.length + 1)
            }
        }
        replaceRangeUndoably(
            range, with: NSAttributedString(), actionName: "이미지 지우기",
            selectionAfter: NSRange(location: range.location, length: 0)
        )
        onNeedsTypingReset?()
    }

    public override func deleteBackward(_ sender: Any?) {
        if let index = selectedImageIndex { deleteImageLine(at: index); return }
        super.deleteBackward(sender)
    }

    public override func deleteForward(_ sender: Any?) {
        if let index = selectedImageIndex { deleteImageLine(at: index); return }
        super.deleteForward(sender)
    }

    public override func copy(_ sender: Any?) {
        if let index = selectedImageIndex { copyImageToPasteboard(at: index); return }
        super.copy(sender)
    }

    public override func cut(_ sender: Any?) {
        if let index = selectedImageIndex {
            copyImageToPasteboard(at: index)
            deleteImageLine(at: index)
            return
        }
        super.cut(sender)
    }

    // MARK: - 이미지 줄 곁에서 글 쓰기

    /// 이미지 줄 바로 앞이나 뒤에서 글을 치려 하면 새 줄을 열어 그리로 옮긴다.
    /// 이미지와 글이 한 줄에 섞이지 않게 하는 장치다. 옮겼으면 true.
    @discardableResult
    func prepareCaretOutsideImageLine() -> Bool {
        guard let textStorage, !isComposingText else { return false }
        let selection = selectedRange()
        let caret: Int
        if let index = selectedImageIndex {
            caret = index + 1
        } else if selection.length == 0 {
            caret = selection.location
        } else {
            return false
        }
        let text = textStorage.string as NSString
        guard caret <= text.length else { return false }
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location

        let isBeforeImage = caret == lineStart && imageAttachment(at: caret) != nil
        let isAfterImage = caret > 0 && imageAttachment(at: caret - 1) != nil
        guard isBeforeImage || isAfterImage else { return false }

        var attributes = typingAttributes
        attributes[.memoBlockStyle] = BlockStyleBox(.paragraph)
        attributes[.attachment] = nil
        let newline = NSAttributedString(string: "\n", attributes: attributes)
        // 앞에서 치면 이미지 위에, 뒤에서 치면 아래에 빈 줄을 만들고 되돌리기에 기록한다.
        replaceRangeUndoably(
            NSRange(location: caret, length: 0), with: newline, actionName: "입력 줄 열기",
            selectionAfter: NSRange(location: isBeforeImage ? caret : caret + 1, length: 0)
        )
        onNeedsTypingReset?()
        return true
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let moved = prepareCaretOutsideImageLine()
        super.insertText(string, replacementRange: moved ? NSRange(location: NSNotFound, length: 0) : replacementRange)
    }

    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // 한글 조합은 첫 글자가 들어올 때만 줄을 연다. 조합 중에는 글자를 건드리지 않는다 (NFR-08).
        let moved = !hasMarkedText() && prepareCaretOutsideImageLine()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: moved ? NSRange(location: NSNotFound, length: 0) : replacementRange)
    }

    // MARK: - 붙여넣기 · 끌어 놓기 (IMG-01)

    /// 클립보드나 끌기 꾸러미에 든 이미지 파일 주소.
    func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    /// 클립보드에 이미지가 있으면 넣고 true. 글이 함께 있으면(표 복사 등) 글이 우선이라 false.
    func pasteImagesIfAny() -> Bool {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: MemoImageClipboard.pasteboardType), pasteImageClipboardData(data) {
            return true
        }
        let urls = imageFileURLs(from: pasteboard)
        if !urls.isEmpty {
            commitComposition()
            if onInsertImageFiles?(urls) == true { return true }
        }

        let hasText = !(pasteboard.string(forType: .string) ?? "").isEmpty
        guard !hasText else { return false }
        for type in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType("public.jpeg"), .tiff] {
            if let data = pasteboard.data(forType: type) {
                commitComposition()
                if onInsertImageData?(data) == true { return true }
            }
        }
        return false
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedImageURLs = imageFileURLs(from: sender.draggingPasteboard)
        if !draggedImageURLs.isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !draggedImageURLs.isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        draggedImageURLs = []
        super.draggingExited(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedImageURLs
        draggedImageURLs = []
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        commitComposition()
        // 놓은 자리에 커서를 두고 넣는다.
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        return onInsertImageFiles?(urls) ?? false
    }

    // MARK: - 우클릭 메뉴 (IMG-04)

    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        commitComposition()
        guard let index = imageIndex(at: point) else { return addingNotionItem(to: super.menu(for: event)) }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: index, length: 1))
        return makeImageMenu()
    }

    /// 기본 우클릭 메뉴 끝에 "노션에 올리기"를 붙인다. 허용되지 않으면 흐리게 두고 이유를 도움말로 적는다.
    private func addingNotionItem(to menu: NSMenu?) -> NSMenu? {
        guard let menu, onRequestNotionUpload != nil else { return menu }
        let allowed = canRequestNotionUpload?() ?? false
        let item = NSMenuItem(title: "노션에 올리기", action: allowed ? #selector(uploadToNotionFromMenu) : nil, keyEquivalent: "")
        item.target = self
        if !allowed { item.toolTip = "암호 메모는 노션에 올릴 수 없습니다" }
        menu.addItem(.separator())
        menu.addItem(item)
        return menu
    }

    @objc private func uploadToNotionFromMenu() {
        onRequestNotionUpload?()
    }

    private func makeImageMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, to target: NSMenu) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            target.addItem(item)
        }
        if onRequestImageText != nil {
            add("글자 읽어서 아래에 넣기", #selector(readTextBelowFromMenu), to: menu)
            add("글자로 바꾸고 이미지 지우기", #selector(replaceWithTextFromMenu), to: menu)
            menu.addItem(.separator())
        }
        add("이미지 복사", #selector(copyImageFromMenu), to: menu)

        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        add("25%", #selector(setImageSize25), to: sizeMenu)
        add("50%", #selector(setImageSize50), to: sizeMenu)
        add("100% (원본)", #selector(setImageSize100), to: sizeMenu)
        add("너비 맞춤", #selector(setImageSizeFit), to: sizeMenu)
        let sizeItem = NSMenuItem(title: "크기", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        add("다른 이름으로 저장…", #selector(saveImageAsFile), to: menu)
        add("Finder에서 보기", #selector(revealImageInFinder), to: menu)
        menu.addItem(.separator())
        add("이미지 지우기", #selector(deleteImageFromMenu), to: menu)
        return menu
    }

    private func currentImage() -> (index: Int, attachment: MemoImageAttachment)? {
        guard let index = selectedImageIndex, let attachment = imageAttachment(at: index) else { return nil }
        return (index, attachment)
    }

    private func currentImageFileURL() -> URL? {
        guard let attachment = currentImage()?.attachment else { return nil }
        return imageStore?.fileURL(for: attachment.reference.fileName)
    }

    @objc private func copyImageFromMenu() {
        if let index = selectedImageIndex { copyImageToPasteboard(at: index) }
    }

    /// 시스템 클립보드 없이도 같은 전달 데이터를 검증할 수 있게 인코딩을 분리한다.
    func imageClipboardData(at index: Int) -> Data? {
        guard let attachment = imageAttachment(at: index),
              let store = imageStore, store.fileExists(attachment.reference.fileName),
              let url = store.fileURL(for: attachment.reference.fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONEncoder().encode(MemoImageClipboard(data: data, alt: attachment.reference.alt, width: attachment.reference.width))
    }

    @discardableResult
    func pasteImageClipboardData(_ data: Data) -> Bool {
        guard let content = try? JSONDecoder().decode(MemoImageClipboard.self, from: data) else { return false }
        commitComposition()
        return onInsertImageContent?(content.data, content.alt, content.width) ?? false
    }

    /// 이미지 데이터와 파일 주소를 함께 클립보드에 올린다. 받는 앱이 편한 쪽을 고른다.
    func copyImageToPasteboard(at index: Int) {
        guard let attachment = imageAttachment(at: index),
              let url = imageStore?.fileURL(for: attachment.reference.fileName),
              let data = try? Data(contentsOf: url)
        else { return }
        let type: NSPasteboard.PasteboardType = url.pathExtension.lowercased() == "png"
            ? .png : NSPasteboard.PasteboardType("public.jpeg")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([type, .fileURL, MemoImageClipboard.pasteboardType], owner: nil)
        if let content = imageClipboardData(at: index) {
            pasteboard.setData(content, forType: MemoImageClipboard.pasteboardType)
        }
        pasteboard.setData(data, forType: type)
        pasteboard.setString(url.absoluteString, forType: .fileURL)
    }

    private func setSelectedImageWidth(percent: Int?) {
        guard let (index, attachment) = currentImage() else { return }
        guard let percent else {
            setImageWidth(nil, at: index, actionName: "이미지 크기")
            return
        }
        guard let natural = imageStore?.naturalSize(of: attachment.reference.fileName) else { return }
        let width = Int((natural.width * CGFloat(percent) / 100).rounded())
        setImageWidth(max(Int(MemoImageAttachment.minimumWidth), width), at: index, actionName: "이미지 크기")
    }

    @objc private func setImageSize25() { setSelectedImageWidth(percent: 25) }
    @objc private func setImageSize50() { setSelectedImageWidth(percent: 50) }
    @objc private func setImageSize100() { setSelectedImageWidth(percent: 100) }
    @objc private func setImageSizeFit() { setSelectedImageWidth(percent: nil) }

    /// 이미지를 다른 이름 · 다른 형식으로 저장한다.
    ///
    /// 메모 창에 붙은 시트로 열어 창 뒤로 숨지 않게 한다. 처음 폴더는 시스템이 기억하는 마지막 폴더다.
    @objc private func saveImageAsFile() {
        guard let (index, attachment) = currentImage(),
              let source = currentImageFileURL(), FileManager.default.fileExists(atPath: source.path)
        else { return }
        let originalExtension = source.pathExtension.lowercased()
        let ordinal = imageOrdinal(of: index)
        let defaultName = { (fileExtension: String) in
            ImageSaveName.defaultName(
                alt: attachment.reference.alt, memoTitle: self.memoTitleProvider?(),
                ordinal: ordinal, fileExtension: fileExtension
            )
        }

        let panel = NSSavePanel()
        panel.title = "이미지를 다른 이름으로 저장"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false
        panel.nameFieldStringValue = defaultName(originalExtension)
        if let type = UTType(filenameExtension: originalExtension) { panel.allowedContentTypes = [type] }

        let formats: [(title: String, format: AttachmentImages.ExportFormat)] = [
            ("원본", .original), ("PNG", .png), ("JPEG", .jpeg),
        ]
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.title))
        let label = NSTextField(labelWithString: "형식:")
        let accessory = NSStackView(views: [label, popup])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory

        /// 고른 형식에 맞게 확장자와 허용 형식을 바꾼다. 이름 칸에 적은 글자는 그대로 둔다.
        let formatBox = FormatBox()
        popup.target = formatBox
        popup.action = #selector(FormatBox.changed(_:))
        formatBox.onChange = { [weak panel] selected in
            guard let panel else { return }
            let format = formats[selected].format
            let newExtension = format.fileExtension ?? originalExtension
            if let type = UTType(filenameExtension: newExtension) { panel.allowedContentTypes = [type] }
            let current = panel.nameFieldStringValue as NSString
            let stem = current.pathExtension.isEmpty ? current as String : current.deletingPathExtension
            panel.nameFieldStringValue = stem + "." + newExtension
        }

        // 메모 창은 떠 있는 창이라 시트가 뒤에 숨지 않도록 앱을 앞으로 가져온다.
        NSApp.activate(ignoringOtherApps: true)
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let selected = formats[max(0, popup.indexOfSelectedItem)].format
            guard response == .OK, let destination = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try AttachmentImages.export(from: source, to: destination, format: selected)
                } catch {
                    self?.showImageSaveError(error)
                }
                withExtendedLifetime(formatBox) {}
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// 그 메모 안에서 몇 번째 이미지인가 (1부터).
    private func imageOrdinal(of index: Int) -> Int {
        guard let textStorage else { return 1 }
        var count = 0
        textStorage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: min(index + 1, textStorage.length))
        ) { value, _, _ in
            if value is MemoImageAttachment { count += 1 }
        }
        return max(1, count)
    }

    private func showImageSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "이미지를 저장하지 못했습니다"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "확인")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// 팝업 선택을 시트에 알리는 작은 목표 객체. 시트가 끝날 때까지만 산다.
    private final class FormatBox: NSObject {
        var onChange: ((Int) -> Void)?
        @objc func changed(_ sender: NSPopUpButton) { onChange?(sender.indexOfSelectedItem) }
    }

    // MARK: - 글자 읽기 (OCR)

    @objc private func readTextBelowFromMenu() { requestImageText(replacingImage: false) }
    @objc private func replaceWithTextFromMenu() { requestImageText(replacingImage: true) }

    private func requestImageText(replacingImage: Bool) {
        guard let request = imageTextRequest(replacingImage: replacingImage) else { return }
        onRequestImageText?(request)
    }

    /// 지금 고른 이미지로 글자 읽기 요청을 만든다. 이미지를 고르지 않았거나 파일이 없으면 nil.
    public func imageTextRequest(replacingImage: Bool) -> ImageTextRequest? {
        guard let (_, attachment) = currentImage(), let url = currentImageFileURL(),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        let thumbnail = imageStore?.thumbnail(of: attachment.reference.fileName, displayWidth: 240, scale: 2)
        return ImageTextRequest(fileURL: url, replacesImage: replacingImage, thumbnail: thumbnail, attachment: attachment)
    }

    @objc private func revealImageInFinder() {
        guard let url = currentImageFileURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func deleteImageFromMenu() {
        if let index = selectedImageIndex { deleteImageLine(at: index) }
    }
}
