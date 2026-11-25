import AppKit
import EditorKit
import MarkdownEngine
import MemoCore
import Services
import SwiftUI

/// 메모 창 맨 위 줄의 AirDrop 받기 · 이미지로 내보내기, 이미지 글자 읽기 시트.
///
/// 받기와 내보내기는 메모 창 안의 단추로 두고, 시트는 메모 창과 따로 뜨는 작은 창이다
/// (메모 창은 테두리 없는 작은 창이라 시트를 붙이면 잘리거나 가려진다).
extension StickyWindowController {
    private static let ink = NSColor(srgbRed: 28 / 255, green: 29 / 255, blue: 32 / 255, alpha: 1)
    private static let lime = NSColor(srgbRed: 212 / 255, green: 245 / 255, blue: 60 / 255, alpha: 1)

    // MARK: - 단추

    func buildAirDropAndExportButtons(buttonSize: CGFloat) {
        let side: CGFloat = 26
        let airDropImage = MemoGlyphs.airDrop(pointSize: buttonSize * 0.8)
        let exportImage = MemoGlyphs.exportImage(pointSize: buttonSize * 0.8)
        for (button, image, help, action) in [
            (airDropButton, airDropImage, "AirDrop으로 이미지 받기 (메모 안 커서 자리에 넣습니다)", #selector(airDropButtonTapped)),
            (exportButton, exportImage, "이미지로 내보내기 (저장 · AirDrop · 복사)", #selector(exportButtonTapped)),
        ] {
            button.target = self
            button.action = action
            button.title = ""
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.image = image
            button.toolTip = help
            button.setAccessibilityLabel(help.components(separatedBy: " (").first ?? help)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.widthAnchor.constraint(equalToConstant: side).isActive = true
            button.heightAnchor.constraint(equalToConstant: side).isActive = true
        }
        updateAirDropButtonAppearance()

        // 받는 중에 오른쪽 위에 붙는 라임 점 (9pt, 먹색 테두리 1.5pt).
        airDropDot.translatesAutoresizingMaskIntoConstraints = false
        airDropDot.wantsLayer = true
        airDropDot.layer?.backgroundColor = Self.lime.cgColor
        airDropDot.layer?.cornerRadius = 4.5
        airDropDot.layer?.borderWidth = 1.5
        airDropDot.layer?.borderColor = Self.ink.cgColor
        airDropDot.isHidden = true
        airDropButton.addSubview(airDropDot)
        NSLayoutConstraint.activate([
            airDropDot.widthAnchor.constraint(equalToConstant: 9),
            airDropDot.heightAnchor.constraint(equalToConstant: 9),
            airDropDot.trailingAnchor.constraint(equalTo: airDropButton.trailingAnchor, constant: 2),
            airDropDot.topAnchor.constraint(equalTo: airDropButton.topAnchor, constant: -2),
        ])

        iconDividerSetup()

        receiveStrip.onStop = { [weak self] in self?.stopAirDropReceiving() }
        textView.memoTitleProvider = { [weak self] in
            guard let self else { return nil }
            let title = self.currentTitle
            return title?.isEmpty == false ? title : nil
        }
        textView.onRequestImageText = { [weak self] request in self?.presentImageText(request) }
    }

    private func iconDividerSetup() {
        let divider = iconDivider
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Self.ink.withAlphaComponent(0.18).cgColor
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    /// 받는 중에는 기호만 진하게 하고 라임 점을 유지한다.
    private func updateAirDropButtonAppearance() {
        let receiving = isReceivingAirDrop
        airDropButton.contentTintColor = NSColor.black.withAlphaComponent(receiving ? 0.9 : 0.62)
        exportButton.contentTintColor = NSColor.black.withAlphaComponent(0.62)
        airDropDot.isHidden = !receiving
        airDropButton.setAccessibilityValue(receiving ? "받는 중" : nil)
    }

    @objc func airDropButtonTapped() {
        if isReceivingAirDrop { stopAirDropReceiving() } else { startAirDropReceiving() }
    }

    @objc func exportButtonTapped() {
        presentExportSheet()
    }

    // MARK: - AirDrop 받기

    public var isReceivingAirDrop: Bool { airDropReceiver?.isActive ?? false }

    /// 이 메모의 커서 자리에 AirDrop으로 받은 사진을 넣기 시작한다 (2분). 이미 받는 중이면 아무 일도 없다.
    public func startAirDropReceiving() {
        guard !isReceivingAirDrop else { return }
        let receiver = AirDropReceiver()
        receiver.onReceive = { [weak self] url in
            guard let self else { return }
            if self.formatController?.insertReceivedImages([url]) == true { self.scheduleBodySave() }
        }
        receiver.onChange = { [weak self] in self?.refreshAirDropUI() }
        airDropReceiver = receiver
        receiver.start()
        refreshAirDropUI()
    }

    /// 받기를 멈추고 감시 자원을 모두 푼다.
    public func stopAirDropReceiving() {
        guard let receiver = airDropReceiver else { return }
        receiver.onChange = nil
        receiver.stop()
        airDropReceiver = nil
        refreshAirDropUI()
        layoutSections()
    }

    private func refreshAirDropUI() {
        let wasShown = !receiveStrip.isHidden
        if let receiver = airDropReceiver, receiver.isActive {
            receiveStrip.update(
                remaining: receiver.remainingSeconds, total: Int(receiver.duration), received: receiver.receivedCount
            )
        }
        updateAirDropButtonAppearance()
        let shouldShow = isReceivingAirDrop && !isWindowCollapsed
        if shouldShow != wasShown { layoutSections() }
    }

    /// 창을 닫거나 내릴 때. 받기도 멈추고 떠 있는 보조 창도 닫는다.
    func tearDownAirDropAndSheets() {
        stopAirDropReceiving()
        for window in auxiliaryWindows { window.close() }
        auxiliaryWindows.removeAll()
    }

    // MARK: - 이미지 글자 읽기

    private final class Flag { var isClosed = false }

    func presentImageText(_ request: ImageTextRequest) {
        let model = ImageTextSheetModel(thumbnail: request.thumbnail, replacesImage: request.replacesImage)
        let host = NSHostingView(rootView: ImageTextSheetView(model: model))
        let window = AuxiliaryWindow(
            title: request.replacesImage ? "글자로 바꾸고 이미지 지우기" : "글자 읽어서 아래에 넣기",
            contentSize: NSSize(width: 640, height: 400), content: host
        )
        let flag = Flag()
        model.onCancel = { [weak window] in window?.close() }
        model.onInsert = { [weak self, weak window] text, isPlain in
            guard let self else { return }
            if self.formatController?.applyImageText(text, isPlain: isPlain, for: request) == true {
                self.scheduleBodySave()
            }
            window?.close()
            self.panel.makeFirstResponder(self.textView)
        }
        track(window) { flag.isClosed = true }
        window.show()

        let url = request.fileURL
        Task { @MainActor in
            let lines = await OCRService.recognize(imageAt: url)
            if !flag.isClosed { model.finish(with: lines) }
        }
    }

    /// 보조 창을 붙들고, 닫히면 놓는다.
    private func track(_ window: AuxiliaryWindow, onClose: @escaping () -> Void) {
        auxiliaryWindows.append(window)
        window.onClose = { [weak self, weak window] in
            onClose()
            self?.auxiliaryWindows.removeAll { $0 === window }
        }
    }

    // MARK: - 이미지로 내보내기

    private var flowIsRenderable: Bool { hasFlow && !flowStrip.isHidden }

    private var exportBackgroundColor: NSColor {
        guard let rgb = MemoColor.components(fromHex: meta.colorHex) else { return .white }
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    private var exportFooterText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy. M. d."
        return "\(formatter.string(from: meta.modified)) · MDemo"
    }

    private var exportFileStem: String {
        let title = ImageSaveName.sanitized(currentTitle ?? "")
        return title.isEmpty ? "메모" : title
    }

    /// 내보내기 시트를 연다. 이미 열려 있으면 앞으로 가져온다.
    public func presentExportSheet() {
        if let existing = auxiliaryWindows.first(where: { $0.window.title == "이미지로 내보내기" }) {
            existing.show()
            return
        }
        let flowStrip = self.flowStrip
        let model = ExportSheetModel(
            hasFlow: flowIsRenderable,
            layoutProvider: { [weak self] options in
                guard let self else { return options.layout(contentSize: .zero, flowHeight: 0) }
                return options.layout(
                    contentSize: self.textView.exportContentSize(),
                    flowHeight: self.flowIsRenderable ? flowStrip.bounds.height : 0
                )
            },
            renderer: { [weak self] options in
                guard let self else { return nil }
                return MemoExportRenderer.render(
                    textView: self.textView,
                    flowStrip: self.flowIsRenderable ? flowStrip : nil,
                    options: options,
                    backgroundColor: self.exportBackgroundColor,
                    footerText: self.exportFooterText
                )
            }
        )
        let host = NSHostingView(rootView: ExportSheetView(model: model))
        let window = AuxiliaryWindow(title: "이미지로 내보내기", contentSize: NSSize(width: 640, height: 440), content: host)
        var temporaryFolders: [URL] = []

        model.onClose = { [weak window] in window?.close() }
        model.onCopy = { [weak model] in
            guard let model, let data = model.renderer(model.options).flatMap(MemoExportRenderer.pngData) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            model.show(notice: "클립보드에 복사했습니다")
        }
        model.onSave = { [weak self, weak model, weak window] in
            guard let self, let model, let window else { return }
            let panel = NSSavePanel()
            panel.title = "이미지로 저장"
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = "\(self.exportFileStem).png"
            panel.beginSheetModal(for: window.window) { response in
                guard response == .OK, let destination = panel.url else { return }
                MainActor.assumeIsolated {
                    guard let data = model.renderer(model.options).flatMap(MemoExportRenderer.pngData) else {
                        model.show(notice: "이미지를 만들지 못했습니다")
                        return
                    }
                    do {
                        try data.write(to: destination, options: .atomic)
                        model.show(notice: "저장했습니다")
                    } catch {
                        let alert = NSAlert()
                        alert.messageText = "이미지를 저장하지 못했습니다"
                        alert.informativeText = error.localizedDescription
                        alert.beginSheetModal(for: window.window)
                    }
                }
            }
        }
        model.onShare = { [weak self, weak model] in
            guard let self, let model, let anchor = model.shareAnchor,
                  let data = model.renderer(model.options).flatMap(MemoExportRenderer.pngData)
            else { return }
            // 공유는 임시 폴더에 PNG를 만들어 그 주소를 넘긴다. 시트를 닫으면 지운다.
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("mdemo-export-\(UUID().uuidString)", isDirectory: true)
            let file = folder.appendingPathComponent("\(self.exportFileStem).png")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file)
            } catch {
                model.show(notice: "공유할 파일을 만들지 못했습니다")
                return
            }
            temporaryFolders.append(folder)
            NSSharingServicePicker(items: [file]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        track(window) {
            for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) }
            temporaryFolders = []
        }
        window.show()
    }
}
