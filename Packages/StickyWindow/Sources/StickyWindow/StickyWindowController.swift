import AppKit
import EditorKit
import MemoCore

/// 메모 한 개 = 창 한 개. 이 컨트롤러가 창의 수명을 쥔다.
///
/// 메모리 원칙(§4-5): 창이 닫히면 컨트롤러가 통째로 해제되고 본문도 함께 사라진다.
/// 목록에 남는 것은 메타데이터와 미리보기뿐이다.
@MainActor
public final class StickyWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    public let memoID: MemoID
    public private(set) var meta: MemoMeta

    private let panel: StickyPanel
    private let rootView: StickyRootView
    private let textView: MemoTextView
    private let scrollView: NSScrollView
    /// 입력 중 마크다운 기호를 서식으로 바꾼다. 한글 조합 처리를 여기에 가둬 둔다 (NFR-08).
    private var formatController: LiveFormatController?

    /// 저장을 맡은 쪽. 컨트롤러는 파일 시스템을 직접 다루지 않는다 (설계서 §4-3).
    private weak var store: MemoStore?
    private let deviceState: DeviceStateStore

    /// 입력이 멈춘 뒤에 저장한다 (DAT-03). 타이핑마다 디스크를 두드리지 않기 위한 장치다.
    private var saveTimer: Timer?
    private var frameSaveTimer: Timer?
    private static let saveDebounce: TimeInterval = 0.5

    public var onClose: ((MemoID) -> Void)?

    private static let headerHeight: CGFloat = 26

    private var theme: EditorTheme

    public init(
        meta: MemoMeta,
        body: String,
        frame: NSRect,
        theme: EditorTheme,
        store: MemoStore,
        deviceState: DeviceStateStore
    ) {
        self.theme = theme
        self.memoID = meta.id
        self.meta = meta
        self.store = store
        self.deviceState = deviceState
        self.panel = StickyPanel(contentRect: frame)
        self.rootView = StickyRootView(frame: NSRect(origin: .zero, size: frame.size))
        self.scrollView = NSScrollView()
        self.textView = MemoTextView.makeTextKit1(frame: NSRect(origin: .zero, size: frame.size))

        super.init()

        buildViewHierarchy()
        applyAppearance()

        textView.loadMarkdown(body, theme: theme, textAlpha: meta.textAlpha)
        textView.resetTypingAttributes(theme: theme, textAlpha: meta.textAlpha)
        formatController = LiveFormatController(textView: textView, theme: theme, textAlpha: meta.textAlpha)

        textView.delegate = self
        panel.delegate = self
        panel.setAlwaysOnTop(meta.isPinned)
    }

    private func buildViewHierarchy() {
        let header = StickyHeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: "", target: self, action: #selector(closeButtonTapped))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "메모 닫기"
        )
        closeButton.contentTintColor = NSColor.black.withAlphaComponent(0.3)
        closeButton.toolTip = "닫기 (메모는 삭제되지 않습니다)"
        header.addSubview(closeButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        // NSTextView는 스크롤 뷰 안에서 오토레이아웃 대신 리사이징 마스크로 다뤄야 안정적이다.
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        rootView.addSubview(header)
        rootView.addSubview(scrollView)
        rootView.autoresizingMask = [.width, .height]
        panel.contentView = rootView

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootView.topAnchor),
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -6),
        ])
    }

    /// 배경과 텍스트에 각각 알파를 적용한다 (OPA-01/02).
    private func applyAppearance() {
        rootView.apply(colorHex: meta.colorHex, backgroundAlpha: meta.backgroundAlpha)
        // 배경이 밝은 파스텔이므로 다크 모드에서도 글자는 어두운 색이어야 읽힌다.
        textView.applyBaseTextColor(.black)
        textView.applyTextAlpha(meta.textAlpha)
    }

    public func show() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    // MARK: - 저장

    /// 입력이 있을 때마다 서식을 갱신하고, 저장 타이머를 미룬다.
    public func textDidChange(_ notification: Notification) {
        formatController?.textDidChange()
        scheduleBodySave()
    }

    private func scheduleBodySave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDebounce, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveBodyNow()
            }
        }
    }

    /// 지금 즉시 저장한다. 창을 닫거나 앱이 종료될 때는 디바운스를 기다리지 않는다.
    ///
    /// 화면에는 기호가 숨겨져 있으므로, 저장할 때 표준 마크다운으로 되돌린다 (DOC-01).
    public func saveBodyNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        // 조합 중에는 저장하지 않는다. 미완성 글자가 파일에 남으면 다시 열 때 깨진다 (NFR-08).
        guard !textView.isComposingText else {
            scheduleBodySave()
            return
        }
        store?.saveBody(id: memoID, body: textView.currentMarkdown())
    }

    // MARK: - 창 상태

    /// 창 위치·크기는 기기별 파일에만 기록한다 (SYNC-07). 동기화 대상 파일은 건드리지 않는다.
    public func windowDidMove(_ notification: Notification) {
        scheduleFrameSave()
    }

    public func windowDidResize(_ notification: Notification) {
        scheduleFrameSave()
    }

    private func scheduleFrameSave() {
        frameSaveTimer?.invalidate()
        frameSaveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDebounce, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveFrameNow()
            }
        }
    }

    public func saveFrameNow() {
        frameSaveTimer?.invalidate()
        frameSaveTimer = nil

        let frame = panel.frame
        let displayID = panel.screen?.displayIdentifier
        deviceState.setState(
            DeviceMemoState(
                frame: [frame.origin.x, frame.origin.y, frame.width, frame.height],
                displayID: displayID,
                isCollapsed: false
            ),
            for: memoID
        )
    }

    @objc private func closeButtonTapped() {
        close()
    }

    /// 창을 닫는다. 메모 파일은 남는다 (WIN-10).
    public func close() {
        saveBodyNow()
        saveFrameNow()
        store?.setOpen(id: memoID, isOpen: false)
        meta.isOpen = false
        panel.orderOut(nil)
        onClose?(memoID)
    }

    /// 앱 종료 시 호출. 열림 상태는 유지한 채 내용만 확실히 저장한다 (WIN-06).
    public func flushBeforeTermination() {
        saveBodyNow()
        saveFrameNow()
    }

    /// 환경설정에서 글꼴이나 크기를 바꿨을 때 열려 있는 창에 바로 반영한다 (TXT-02, TXT-03).
    public func applyTheme(_ newTheme: EditorTheme) {
        // 조합 중에 다시 그리면 입력하던 글자가 사라진다 (NFR-08).
        guard !textView.isComposingText else { return }
        theme = newTheme
        textView.reapplyTheme(newTheme, textAlpha: meta.textAlpha)
        formatController?.updateAppearance(theme: newTheme, textAlpha: meta.textAlpha)
    }

    public func setHidden(_ hidden: Bool) {
        if hidden {
            panel.orderOut(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    public var currentFrame: NSRect { panel.frame }

    /// 이 컨트롤러가 그 창의 주인인지 확인한다.
    public func owns(_ window: NSWindow) -> Bool { window === panel }
}

private extension NSScreen {
    /// 모니터 식별자. 모니터 구성이 바뀌었을 때 창을 화면 안으로 되돌리는 데 쓴다 (SYS-05).
    var displayIdentifier: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.stringValue
    }
}
