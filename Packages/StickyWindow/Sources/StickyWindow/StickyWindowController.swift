import AppKit
import EditorKit
import MemoCore
import SwiftUI

/// 메모 한 개 = 창 한 개. 이 컨트롤러가 창의 수명을 쥔다.
///
/// 메모리 원칙(§4-5): 창이 닫히면 컨트롤러가 통째로 해제되고 본문도 함께 사라진다.
/// 목록에 남는 것은 메타데이터와 미리보기뿐이다.
@MainActor
public final class StickyWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate, NSPopoverDelegate {
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

    /// 제목 영역과 닫기 버튼 크기는 글자 크기를 따라간다.
    /// 고밀도 화면에서 고정 크기를 쓰면 버튼이 손톱만 해져 누르기 어렵다.
    private var headerHeightConstraint: NSLayoutConstraint?
    private var closeButtonSizeConstraints: [NSLayoutConstraint] = []
    private let closeButton = NSButton()
    private let appearanceButton = NSButton()
    private let pinButton = NSButton()

    /// 가장자리를 잡아 크기를 조절하게 해 주는 겹침 뷰 (WIN-07).
    private let resizeOverlay = ResizeOverlayView()
    /// 겉모습 설정 패널 (WIN-11, OPA-*). 열 때 만들고 닫으면 버린다.
    private var appearancePopover: NSPopover?

    /// 접기 전 높이. 펼칠 때 되돌리기 위해 기억해 둔다 (WIN-08).
    private var expandedHeight: CGFloat?
    private var isCollapsed = false

    private func configure(
        _ button: NSButton,
        symbol: String,
        description: String,
        help: String,
        action: Selector,
        size: CGFloat
    ) {
        button.target = self
        button.action = action
        button.title = ""
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .circular
        button.isBordered = false
        button.imageScaling = .scaleProportionallyUpOrDown
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: size * 0.8, weight: .regular))
        button.contentTintColor = NSColor.black.withAlphaComponent(0.35)
        button.toolTip = help
    }

    private static func headerHeight(for fontSize: CGFloat) -> CGFloat {
        max(32, fontSize * 1.7)
    }

    private static func closeButtonSize(for fontSize: CGFloat) -> CGFloat {
        max(20, fontSize * 1.15)
    }

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

        // 슬래시 명령이 있다는 걸 모르면 쓸 수 없으니, 빈 메모에서 한 줄로 알려 준다.
        textView.placeholderText = "/ 를 입력하면 서식 목록"
        textView.loadMarkdown(body, theme: theme, textAlpha: meta.textAlpha)
        textView.resetTypingAttributes(theme: theme, textAlpha: meta.textAlpha)
        formatController = LiveFormatController(textView: textView, theme: theme, textAlpha: meta.textAlpha)

        textView.delegate = self
        panel.delegate = self
        panel.setAlwaysOnTop(meta.isPinned)

        // 마우스를 올리면 잠깐 또렷해지게 한다 (OPA-04).
        rootView.onHoverChange = { [weak self] isHovering in
            self?.setHoverOpaque(isHovering)
        }
    }

    /// 접힌 채로 저장돼 있었다면 그대로 되살린다 (WIN-08).
    public func restoreCollapsedStateIfNeeded() {
        guard deviceState.state(for: memoID)?.isCollapsed == true, !isCollapsed else { return }
        toggleCollapsed()
    }

    /// 마우스를 올린 동안에만 불투명하게 (OPA-04).
    ///
    /// 투명하게 두면 뒤가 비쳐 좋지만, 정작 읽으려 할 때 불편하다.
    /// 읽으려고 마우스를 가져가는 순간에만 또렷해지면 두 가지를 다 얻는다.
    private var isHoverOpaqueEnabled = true

    public func setHoverOpaqueEnabled(_ enabled: Bool) {
        isHoverOpaqueEnabled = enabled
        if !enabled {
            setHoverOpaque(false)
        }
    }

    private func setHoverOpaque(_ isHovering: Bool) {
        guard isHoverOpaqueEnabled else { return }
        // 이미 불투명하면 바꿀 것이 없다.
        guard meta.backgroundAlpha < 1.0 || meta.textAlpha < 1.0 else { return }

        let background = isHovering ? 1.0 : meta.backgroundAlpha
        let text = isHovering ? 1.0 : meta.textAlpha
        rootView.apply(colorHex: meta.colorHex, backgroundAlpha: background)
        textView.applyTextAlpha(text)
    }

    private func buildViewHierarchy() {
        let header = StickyHeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let buttonSize = Self.closeButtonSize(for: theme.baseFontSize)
        closeButton.target = self
        closeButton.action = #selector(closeButtonTapped)
        closeButton.title = ""
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyUpOrDown
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "메모 닫기"
        )?.withSymbolConfiguration(.init(pointSize: buttonSize, weight: .regular))
        closeButton.contentTintColor = NSColor.black.withAlphaComponent(0.35)
        closeButton.toolTip = "닫기 (메모는 삭제되지 않습니다)"
        header.addSubview(closeButton)

        configure(
            appearanceButton,
            symbol: "paintpalette.fill",
            description: "겉모습",
            help: "배경색과 투명도",
            action: #selector(appearanceButtonTapped),
            size: buttonSize
        )
        header.addSubview(appearanceButton)

        configure(
            pinButton,
            symbol: meta.isPinned ? "pin.fill" : "pin.slash",
            description: "항상 위",
            help: "항상 위에 두기 (WIN-03)",
            action: #selector(pinButtonTapped),
            size: buttonSize
        )
        header.addSubview(pinButton)

        // 제목 영역을 두 번 누르면 접히고 펼쳐진다 (WIN-08).
        header.onDoubleClick = { [weak self] in self?.toggleCollapsed() }

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
        // 가장자리 감지는 맨 위에 둬야 한다. 가장자리 밖에서는 마우스를 그대로 통과시킨다.
        resizeOverlay.frame = rootView.bounds
        resizeOverlay.autoresizingMask = [.width, .height]
        resizeOverlay.minimumSize = panel.minSize
        rootView.addSubview(resizeOverlay)

        rootView.autoresizingMask = [.width, .height]
        panel.contentView = rootView

        let headerHeight = header.heightAnchor.constraint(
            equalToConstant: Self.headerHeight(for: theme.baseFontSize)
        )
        let buttonWidth = closeButton.widthAnchor.constraint(equalToConstant: buttonSize)
        let buttonHeight = closeButton.heightAnchor.constraint(equalToConstant: buttonSize)
        headerHeightConstraint = headerHeight
        closeButtonSizeConstraints = [buttonWidth, buttonHeight]

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootView.topAnchor),
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            headerHeight,

            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            buttonWidth,
            buttonHeight,

            appearanceButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            appearanceButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            appearanceButton.widthAnchor.constraint(equalTo: closeButton.widthAnchor),
            appearanceButton.heightAnchor.constraint(equalTo: closeButton.heightAnchor),

            pinButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pinButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            pinButton.widthAnchor.constraint(equalTo: closeButton.widthAnchor),
            pinButton.heightAnchor.constraint(equalTo: closeButton.heightAnchor),

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

    /// 바깥에서 본문에 글자를 넣는다.
    /// 지금은 동작 확인용이고, 템플릿 삽입(FUT-04)에서도 같은 경로를 쓴다.
    public func insertText(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
        formatController?.textDidChange()
    }

    /// 엔터를 눌렀을 때와 같은 경로를 태운다. 실행 중인 앱에서 동작을 확인할 때 쓴다.
    public func simulateReturnKey() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ) else { return }
        textView.keyDown(with: event)
    }

    /// 슬래시 팝업의 실제 치수.
    public var slashPopupDiagnostics: String {
        formatController?.slashPopupDiagnostics ?? "편집기 없음"
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

    /// 다른 창으로 넘어가면 떠 있던 팝업을 정리한다.
    /// 팝업이 남아 있으면 엔터·방향키를 계속 가로채 입력이 먹통처럼 보인다.
    public func windowDidResignKey(_ notification: Notification) {
        formatController?.dismissPopups()
    }

    /// 창 위치·크기는 기기별 파일에만 기록한다 (SYNC-07). 동기화 대상 파일은 건드리지 않는다.
    public func windowDidMove(_ notification: Notification) {
        formatController?.dismissPopups()
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
        // 접힌 상태에서는 펼쳤을 때의 높이를 저장한다. 다음에 열 때 접힌 채로 뜨면 곤란하다.
        let heightToSave = isCollapsed ? (expandedHeight ?? frame.height) : frame.height
        deviceState.setState(
            DeviceMemoState(
                frame: [frame.origin.x, frame.origin.y, frame.width, heightToSave],
                displayID: displayID,
                isCollapsed: isCollapsed
            ),
            for: memoID
        )
    }

    @objc private func closeButtonTapped() {
        close()
    }

    // MARK: - 겉모습 (WIN-11, OPA-01/02/03)

    @objc private func appearanceButtonTapped() {
        if let popover = appearancePopover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let view = StickyAppearanceView(
            colorHex: meta.colorHex,
            backgroundAlpha: meta.backgroundAlpha,
            textAlpha: meta.textAlpha,
            isPinned: meta.isPinned,
            onColorChange: { [weak self] hex in self?.setColor(hex) },
            onBackgroundAlphaChange: { [weak self] value in self?.setBackgroundAlpha(value) },
            onTextAlphaChange: { [weak self] value in self?.setTextAlpha(value) },
            onPinnedChange: { [weak self] value in self?.setPinned(value) }
        )

        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: view)
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: appearanceButton.bounds, of: appearanceButton, preferredEdge: .maxY)
        appearancePopover = popover
    }

    public func setColor(_ hex: String) {
        meta.colorHex = hex
        rootView.apply(colorHex: hex, backgroundAlpha: meta.backgroundAlpha)
        store?.updateMeta(id: memoID) { $0.colorHex = hex }
    }

    /// 배경 레이어에만 적용한다. 글씨는 건드리지 않는다 (OPA-01).
    public func setBackgroundAlpha(_ value: Double) {
        let clamped = MemoMeta.clampBackgroundAlpha(value)
        meta.backgroundAlpha = clamped
        rootView.apply(colorHex: meta.colorHex, backgroundAlpha: clamped)
        store?.updateMeta(id: memoID) { $0.backgroundAlpha = clamped }
    }

    /// 글자 색의 알파만 바꾼다. 창 전체 알파는 끝까지 1.0으로 둔다 (OPA-02).
    public func setTextAlpha(_ value: Double) {
        let clamped = MemoMeta.clampTextAlpha(value)
        meta.textAlpha = clamped
        textView.reapplyTheme(theme, textAlpha: clamped)
        formatController?.updateAppearance(theme: theme, textAlpha: clamped)
        store?.updateMeta(id: memoID) { $0.textAlpha = clamped }
    }

    @objc private func pinButtonTapped() {
        setPinned(!meta.isPinned)
    }

    /// 항상 위 토글 (WIN-03).
    public func setPinned(_ isPinned: Bool) {
        meta.isPinned = isPinned
        panel.setAlwaysOnTop(isPinned)
        pinButton.image = NSImage(
            systemSymbolName: isPinned ? "pin.fill" : "pin.slash",
            accessibilityDescription: "항상 위"
        )?.withSymbolConfiguration(.init(pointSize: Self.closeButtonSize(for: theme.baseFontSize) * 0.8, weight: .regular))
        store?.updateMeta(id: memoID) { $0.isPinned = isPinned }
    }

    // MARK: - 접기 (WIN-08)

    /// 제목 영역만 남기고 접는다. 다시 두 번 누르면 원래 높이로 돌아온다.
    public func toggleCollapsed() {
        let headerHeight = Self.headerHeight(for: theme.baseFontSize)
        var frame = panel.frame

        if isCollapsed {
            let restored = expandedHeight ?? (headerHeight * 6)
            frame.origin.y -= (restored - frame.height)
            frame.size.height = restored
            isCollapsed = false
        } else {
            expandedHeight = frame.height
            frame.origin.y += (frame.height - headerHeight)
            frame.size.height = headerHeight
            isCollapsed = true
        }

        // 접힌 동안에는 내용이 보이지 않아야 하므로 최소 높이를 잠시 낮춘다.
        panel.minSize = NSSize(width: panel.minSize.width, height: isCollapsed ? headerHeight : 120)
        resizeOverlay.minimumSize = panel.minSize
        panel.setFrame(frame, display: true, animate: false)
        scrollView.isHidden = isCollapsed
        saveFrameNow()
    }

    /// 창을 닫는다. 메모 파일은 남는다 (WIN-10).
    public func close() {
        formatController?.dismissPopups()
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

        // 제목 영역과 닫기 버튼도 새 글자 크기에 맞춘다.
        let buttonSize = Self.closeButtonSize(for: newTheme.baseFontSize)
        headerHeightConstraint?.constant = Self.headerHeight(for: newTheme.baseFontSize)
        closeButtonSizeConstraints.forEach { $0.constant = buttonSize }
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "메모 닫기"
        )?.withSymbolConfiguration(.init(pointSize: buttonSize, weight: .regular))
    }

    public func setHidden(_ hidden: Bool) {
        if hidden {
            formatController?.dismissPopups()
            panel.orderOut(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    public var currentFrame: NSRect { panel.frame }

    /// 이 컨트롤러가 그 창의 주인인지 확인한다.
    public func owns(_ window: NSWindow) -> Bool { window === panel }

    /// 창 레벨. 항상 위 설정이 실제로 적용됐는지 확인할 때 쓴다 (WIN-03).
    public var windowLevel: NSWindow.Level { panel.level }
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
