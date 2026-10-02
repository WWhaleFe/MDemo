import AppKit
import EditorKit
import MarkdownEngine
import MemoCore
import Services
import SwiftUI

/// 메모 한 개 = 창 한 개. 이 컨트롤러가 창의 수명을 쥔다.
///
/// 메모리 원칙(§4-5): 창이 닫히면 컨트롤러가 통째로 해제되고 본문도 함께 사라진다.
/// 목록에 남는 것은 메타데이터와 미리보기뿐이다.
@MainActor
public final class StickyWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate, NSPopoverDelegate, NSTextFieldDelegate {
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
    /// 사용자가 창 크기를 직접 바꿨을 때. 새 메모의 기본 크기로 쓴다.
    public var onUserResized: ((NSSize) -> Void)?

    /// 닫기는 맥 규칙대로 왼쪽 위에 신호등으로 둔다 (WIN-02).
    private let trafficLights = TrafficLightGroup()
    private let closeButton = TrafficLightButton(help: "닫기 (메모는 삭제되지 않습니다)")
    private let appearanceButton = NSButton()
    private let pinButton = NSButton()
    /// 머리 영역의 접기 버튼 (WIN-08). 접기·펼치기는 이 버튼 하나로 한다.
    private let foldButton = NSButton()
    /// 메모 제목 (TXT-06). 머리 영역을 누르면 바로 고쳐 쓸 수 있다.
    private let titleField = NSTextField()
    /// 서식 버튼 이름표 (FMT-05). 마우스를 올린 동안에만 뜬다.
    private let toolbarHintLabel = ToolbarHintView()
    /// 배경 투명도 슬라이더 (OPA-01). 가장 자주 만지는 값이라 머리 영역에 바로 둔다.
    private let opacitySlider = OpacitySlider.make()
    private var opacitySliderWidthConstraint: NSLayoutConstraint?
    /// 슬라이더를 끄는 동안 파일에 쓰지 않기 위한 지연 저장.
    private var alphaSaveTimer: Timer?

    /// 서식 막대 (FMT-01). 위·아래 어느 쪽에 붙일지는 설정을 따른다.
    private let formatToolbar: FormatToolbarView
    private var toolbarPosition: FormatToolbarPosition
    /// 막대의 자리에 따라 갈아 끼우는 배치 제약. 바뀔 때마다 통째로 교체한다.
    private var sectionConstraints: [NSLayoutConstraint] = []

    /// 서식 막대에서 글자 크기를 바꿨을 때. 전역 설정이라 창 하나가 정할 일이 아니다.
    public var onRequestFontStep: ((Int) -> Void)?

    /// 머리 영역. 배치를 다시 잡을 때 기준으로 쓴다.
    private var header: StickyHeaderView?

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

    /// 머리 영역 전체 높이 = 버튼 줄 + 제목 줄.
    /// 버튼·아이콘 크기의 기준 글자 크기.
    ///
    /// 예전에는 본문 글자 크기를 따라 버튼도 커지고 작아졌는데, 글자만 키우고 싶을 때
    /// 창 머리와 서식 막대까지 덩달아 커져 본문 자리를 잡아먹었다.
    /// 지금 쓰는 크기(20pt)에서 보기 좋은 버튼 크기를 그대로 고정해 둔다.
    static let chromeFontSize: CGFloat = 20

    /// 머리 영역 높이 = 버튼 줄 + 간격 + 제목 줄.
    /// 제목도 버튼처럼 크기를 고정하므로, 본문 글자 크기를 바꿔도 머리 영역은 그대로다.
    private static var headerHeight: CGFloat {
        controlRowTopInset + controlRowHeight(for: chromeFontSize) + titleGap + titleRowHeight(for: chromeFontSize)
    }

    /// 머리 영역(또는 위쪽 서식 막대)과 본문 첫 줄 사이 간격.
    private static let bodyTopSpacing: CGFloat = 10

    /// 버튼 줄을 창 위 가장자리에서 띄우는 거리.
    /// 위 가장자리 띠는 크기 조절 자리라, 버튼이 걸치면 버튼 윗부분을 누를 때 크기 조절이 시작된다.
    private static let controlRowTopInset: CGFloat = 6

    /// 버튼 줄과 제목 사이 간격. 붙어 있으면 제목이 닫기 버튼에 딸린 이름표처럼 보인다.
    private static let titleGap: CGFloat = 6

    /// 버튼 줄. 버튼 사이의 빈 곳은 창을 잡아 옮기는 자리다.
    private static func controlRowHeight(for fontSize: CGFloat) -> CGFloat {
        max(28, fontSize * 1.5)
    }

    /// 제목 줄. 제목 글자(본문의 0.72배)가 들어갈 만큼만 둔다.
    private static func titleRowHeight(for fontSize: CGFloat) -> CGFloat {
        ceil(titleFontSize(for: fontSize) * 1.4)
    }

    /// 메모 제목 글자 크기. 기준 크기 그대로, 굵게 써서 이름표로 읽힌다.
    static func titleFontSize(for fontSize: CGFloat) -> CGFloat {
        max(12, fontSize.rounded())
    }

    private static func closeButtonSize(for fontSize: CGFloat) -> CGFloat {
        max(20, fontSize * 1.15)
    }

    /// 신호등 지름. 맥 기본값은 12pt 고정이지만, 글자를 키워 쓰는 화면에서는 그만큼 따라 키운다.
    private static func trafficLightSize(for fontSize: CGFloat) -> CGFloat {
        max(14, min(fontSize * 0.85, 22))
    }

    private var theme: EditorTheme

    public init(
        meta: MemoMeta,
        body: String,
        frame: NSRect,
        theme: EditorTheme,
        toolbarPosition: FormatToolbarPosition = .top,
        store: MemoStore,
        deviceState: DeviceStateStore
    ) {
        self.theme = theme
        self.memoID = meta.id
        self.meta = meta
        self.store = store
        self.deviceState = deviceState
        self.toolbarPosition = toolbarPosition
        self.panel = StickyPanel(contentRect: frame)
        self.rootView = StickyRootView(frame: NSRect(origin: .zero, size: frame.size))
        self.scrollView = NSScrollView()
        self.textView = MemoTextView.makeTextKit1(frame: NSRect(origin: .zero, size: frame.size))
        self.formatToolbar = FormatToolbarView(fontSize: Self.chromeFontSize, position: toolbarPosition)

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

    /// 사용자가 끌어서 크기를 바꾼 뒤. 마지막으로 맞춘 크기가 다음 새 메모의 크기가 된다.
    /// 접힌 창의 폭만 바꾼 경우는 높이가 제목 줄뿐이라 기본값으로 삼지 않는다.
    public func userDidResize(to size: NSSize) {
        guard !isCollapsed else { return }
        onUserResized?(size)
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

        buildTrafficLights(into: header)

        let buttonSize = Self.closeButtonSize(for: Self.chromeFontSize)
        configure(
            appearanceButton,
            symbol: "paintpalette.fill",
            description: "겉모습",
            help: "배경색과 투명도",
            action: #selector(appearanceButtonTapped),
            size: buttonSize
        )
        header.addSubview(appearanceButton)

        buildOpacitySlider(into: header)

        configure(
            pinButton,
            symbol: meta.isPinned ? "pin.fill" : "pin.slash",
            description: "항상 위",
            help: "항상 위에 두기 (WIN-03)",
            action: #selector(pinButtonTapped),
            size: buttonSize
        )
        header.addSubview(pinButton)

        configure(
            foldButton,
            symbol: "rectangle.compress.vertical",
            description: "접기",
            help: "접기 / 펼치기 (WIN-08)",
            action: #selector(foldButtonTapped),
            size: buttonSize
        )
        header.addSubview(foldButton)
        // 시스템에 없는 기호면 화살표로 물러서도록 그림은 한곳에서 정한다.
        updateFoldButtonImage()

        buildTitleField(into: header)

        formatToolbar.onCommand = { [weak self] command in
            self?.handleToolbarCommand(command)
        }
        formatToolbar.onHoverItem = { [weak self] text, frame in
            self?.showToolbarHint(text, near: frame)
        }

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
        resizeOverlay.onResizeEnded = { [weak self] size in
            self?.userDidResize(to: size)
        }
        rootView.addSubview(resizeOverlay)

        rootView.autoresizingMask = [.width, .height]
        panel.contentView = rootView

        self.header = header

        let headerHeight = header.heightAnchor.constraint(equalToConstant: Self.headerHeight)

        // 위 줄은 버튼, 아래 줄은 제목.
        // 예전에는 제목이 버튼 사이를 다 채워서, 창을 잡을 빈 곳이 거의 없었다.
        let controlRow = NSLayoutGuide()
        header.addLayoutGuide(controlRow)
        let controlRowHeight = controlRow.heightAnchor.constraint(
            equalToConstant: Self.controlRowHeight(for: Self.chromeFontSize)
        )

        let buttonWidth = appearanceButton.widthAnchor.constraint(equalToConstant: buttonSize)
        let buttonHeight = appearanceButton.heightAnchor.constraint(equalToConstant: buttonSize)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootView.topAnchor),
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            headerHeight,

            controlRow.topAnchor.constraint(equalTo: header.topAnchor, constant: Self.controlRowTopInset),
            controlRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            controlRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            controlRowHeight,

            trafficLights.centerYAnchor.constraint(equalTo: controlRow.centerYAnchor),

            // 겉모습·항상 위는 오른쪽으로 밀어 둔다. 왼쪽 위는 신호등 자리다.
            appearanceButton.centerYAnchor.constraint(equalTo: controlRow.centerYAnchor),
            // 오른쪽 가장자리 띠(크기 조절 자리)에 걸치지 않게 띄운다.
            appearanceButton.trailingAnchor.constraint(
                equalTo: header.trailingAnchor,
                constant: -(ResizeOverlayView.edgeThickness + 2)
            ),
            buttonWidth,
            buttonHeight,

            // 접기는 고정하기 바로 오른쪽. 창을 다루는 버튼끼리 붙여 둔다 (WIN-08).
            foldButton.centerYAnchor.constraint(equalTo: controlRow.centerYAnchor),
            foldButton.trailingAnchor.constraint(equalTo: appearanceButton.leadingAnchor, constant: -8),
            foldButton.widthAnchor.constraint(equalTo: appearanceButton.widthAnchor),
            foldButton.heightAnchor.constraint(equalTo: appearanceButton.heightAnchor),

            pinButton.centerYAnchor.constraint(equalTo: controlRow.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: foldButton.leadingAnchor, constant: -8),
            pinButton.widthAnchor.constraint(equalTo: appearanceButton.widthAnchor),
            pinButton.heightAnchor.constraint(equalTo: appearanceButton.heightAnchor),

            // 투명도는 고정하기 바로 왼쪽에 둔다. 창을 흐리게 해 두고 고정하는 손이 이어진다.
            opacitySlider.centerYAnchor.constraint(equalTo: controlRow.centerYAnchor),
            opacitySlider.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -8),

            // 제목은 버튼 줄 아래 한 줄, 메모 전체 너비의 가운데에 둔다.
            // 양옆 여백을 같게 잡아야 글자가 창 한가운데에 온다.
            titleField.topAnchor.constraint(equalTo: controlRow.bottomAnchor, constant: Self.titleGap),
            titleField.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
            titleField.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
        ])

        layoutSections()
    }

    /// 왼쪽 위 닫기.
    ///
    /// 닫기는 맥의 신호등을 그대로 쓴다. 맥에서 창을 닫으려는 손은 늘 왼쪽 위로 가기 때문이다.
    /// 접기는 오른쪽 머리 영역의 버튼 하나로 한다 (WIN-08).
    private func buildTrafficLights(into header: StickyHeaderView) {
        let size = Self.trafficLightSize(for: Self.chromeFontSize)

        closeButton.target = self
        closeButton.action = #selector(closeButtonTapped)


        trafficLights.translatesAutoresizingMaskIntoConstraints = false
        trafficLights.addSubview(closeButton)
        header.addSubview(trafficLights)

        let closeWidth = closeButton.widthAnchor.constraint(equalToConstant: size)
        let closeHeight = closeButton.heightAnchor.constraint(equalToConstant: size)

        NSLayoutConstraint.activate([
            trafficLights.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            trafficLights.topAnchor.constraint(equalTo: closeButton.topAnchor),
            trafficLights.bottomAnchor.constraint(equalTo: closeButton.bottomAnchor),
            trafficLights.leadingAnchor.constraint(equalTo: closeButton.leadingAnchor),
            trafficLights.trailingAnchor.constraint(equalTo: closeButton.trailingAnchor),

            closeWidth,
            closeHeight,
        ])
    }

    /// 메모 제목 (TXT-06).
    ///
    /// 예전에는 머리 영역을 두 번 누르면 접혔는데, 창 맨 위는 제목을 쓰려고 누르는 자리다.
    /// 접기는 버튼으로 옮기고(WIN-08), 이 자리는 제목에 내준다.
    private func buildTitleField(into header: StickyHeaderView) {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = meta.title ?? ""
        titleField.placeholderString = "제목 없음"
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.alignment = .center
        // 서식 있는 글을 붙여 넣어도 제목 글꼴(굵게)이 바뀌지 않게 한다.
        titleField.allowsEditingTextAttributes = false
        titleField.importsGraphics = false
        titleField.usesSingleLineMode = true
        titleField.cell?.sendsActionOnEndEditing = true
        titleField.target = self
        titleField.action = #selector(titleChanged)
        titleField.delegate = self
        applyTitleFont()
        header.addSubview(titleField)
    }

    /// 안내 문구도 제목과 같이 가운데에 둔다. 속성 문자열은 칸의 정렬을 따르지 않는다.
    private static let centeredParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()

    private func applyTitleFont() {
        // 크기는 고정, 글꼴 종류만 설정을 따른다.
        let size = Self.titleFontSize(for: Self.chromeFontSize)
        // 제목은 늘 굵게. 고른 글꼴에 굵은 꼴이 없으면 시스템 굵은 글꼴로 물러선다.
        let font = FontResolver.font(family: theme.fontFamily, size: size, traits: [.boldFontMask])
        titleField.font = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
            ? font
            : NSFont.systemFont(ofSize: size, weight: .bold)
        titleField.textColor = NSColor.black.withAlphaComponent(0.65)
        // 기본 안내 글씨는 어두운 화면 모드에서 흰색이 되어, 밝은 메모 배경에서 보이지 않는다.
        titleField.placeholderAttributedString = NSAttributedString(
            string: "제목 없음",
            attributes: [
                .font: titleField.font ?? NSFont.boldSystemFont(ofSize: size),
                .foregroundColor: NSColor.black.withAlphaComponent(0.3),
                .paragraphStyle: Self.centeredParagraph,
            ]
        )
    }

    /// 제목을 고치는 동안에도 굵게 보이게 한다.
    ///
    /// 고쳐 쓰는 동안 글자를 그리는 것은 제목 칸이 아니라 창이 함께 쓰는 편집 칸이다.
    /// 그 칸은 다른 곳(본문 등)에서 쓰던 글꼴을 들고 올 수 있어, 제목 칸의 글꼴을 다시 쥐여 준다.
    public func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleField,
              let editor = titleField.currentEditor() as? NSTextView,
              let font = titleField.font
        else { return }
        editor.font = font
        editor.typingAttributes[.font] = font
    }

    /// 제목을 고쳐 쓰면 파일에 남긴다. 빈칸으로 두면 본문 첫 줄이 다시 제목 노릇을 한다.
    @objc private func titleChanged() {
        let trimmed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle: String? = trimmed.isEmpty ? nil : trimmed
        guard newTitle != meta.title else { return }
        meta.title = newTitle
        store?.updateMeta(id: memoID) { $0.title = newTitle }
    }

    /// 제목 칸에서 엔터를 치면 본문으로 넘어간다. 제목만 쓰고 멈추는 일이 없게 한다.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === titleField, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        titleChanged()
        panel.makeFirstResponder(self.textView)
        return true
    }

    /// 제목을 밖에서 바꾼다. 화면과 파일을 함께 맞춘다 (TXT-06).
    public func setTitle(_ title: String?) {
        titleField.stringValue = title ?? ""
        titleChanged()
    }

    /// 지금 붙어 있는 제목. 비어 있으면 nil.
    public var currentTitle: String? { meta.title }

    /// 제목 칸의 글꼴. 굵게·고정 크기가 지켜지는지 확인할 때 쓴다.
    public var titleFont: NSFont? { titleField.font }

    @objc private func foldButtonTapped() {
        toggleCollapsed()
    }

    /// 접힘 상태에 따라 접기 버튼의 그림을 바꾼다.
    /// 지금 누르면 무엇이 일어날지 버튼이 말해 준다.
    ///
    /// 창을 접는다는 뜻이 분명한 그림을 쓰고,
    /// 시스템에 없는 이름이면 화살표로 물러선다 — 빈 버튼이 남는 것보다 낫다.
    private func updateFoldButtonImage() {
        let size = Self.closeButtonSize(for: Self.chromeFontSize)
        foldButton.image = Self.symbolImage(
            names: isCollapsed
                ? ["rectangle.expand.vertical", "chevron.down"]
                : ["rectangle.compress.vertical", "chevron.up"],
            pointSize: size * 0.8,
            description: isCollapsed ? "펼치기" : "접기"
        )
        foldButton.toolTip = isCollapsed ? "펼치기" : "접기 (제목 줄만 남기기)"
    }

    /// 여러 후보 중 이 시스템에 있는 첫 기호를 쓴다.
    private static func symbolImage(names: [String], pointSize: CGFloat, description: String) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
                return image.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
            }
        }
        return nil
    }

    // MARK: - 서식 버튼 이름표 (FMT-05)

    /// 이름표 글자 크기. 본문 크기를 따라가되 너무 작아지지 않게 바닥을 둔다.
    private var toolbarHintFontSize: CGFloat {
        max(13, Self.chromeFontSize * 0.62)
    }

    /// 마우스를 올린 버튼의 이름을 그 옆에 띄운다.
    ///
    /// 시스템 툴팁을 쓰지 않는 이유는 이 앱이 메뉴바 앱이기 때문이다.
    /// 메모 창은 대개 비활성이라, 시스템은 툴팁을 띄우지 않는다.
    private func showToolbarHint(_ text: String?, near buttonFrame: NSRect) {
        guard let text, !text.isEmpty else {
            hideToolbarHint()
            return
        }

        if toolbarHintLabel.superview !== rootView {
            rootView.addSubview(toolbarHintLabel, positioned: .below, relativeTo: resizeOverlay)
        }

        // 자리는 제약이 아니라 좌표로 직접 잡는다.
        //
        // 오토레이아웃으로 붙이면 이름표의 너비가 창 크기에 끼어든다.
        // 창의 크기는 레이아웃 엔진에서 우선순위 500짜리 변수라, 그보다 높은 제약이 걸리면
        // 창이 스스로 늘어난다 — 오른쪽 끝 버튼에 마우스를 올렸을 때 창이 갑자기 넓어지던 원인이다.
        // 좌표로 두면 이름표가 창 크기에 아무 영향도 주지 않는다.
        let available = rootView.bounds
        let size = toolbarHintLabel.update(
            text: text,
            font: NSFont.systemFont(ofSize: toolbarHintFontSize, weight: .medium),
            maxWidth: max(40, available.width - 8)
        )

        let anchor = formatToolbar.convert(
            NSPoint(x: buttonFrame.midX, y: buttonFrame.midY),
            to: rootView
        )

        var origin: NSPoint
        if toolbarPosition.isVertical {
            // 세로 막대에서는 버튼 옆(본문 쪽)에 붙인다.
            let x = toolbarPosition == .left
                ? formatToolbar.frame.maxX + 6
                : formatToolbar.frame.minX - 6 - size.width
            origin = NSPoint(x: x, y: anchor.y - size.height / 2)
        } else {
            let y = toolbarPosition == .bottom
                ? formatToolbar.frame.maxY + 4
                : formatToolbar.frame.minY - 4 - size.height
            origin = NSPoint(x: anchor.x - size.width / 2, y: y)
        }

        // 창 밖으로 밀려나지 않게 안으로 당긴다.
        origin.x = min(max(4, origin.x), max(4, available.width - size.width - 4))
        origin.y = min(max(4, origin.y), max(4, available.height - size.height - 4))

        toolbarHintLabel.frame = NSRect(origin: origin, size: size)
        toolbarHintLabel.needsLayout = true
        toolbarHintLabel.isHidden = false
    }

    private func hideToolbarHint() {
        toolbarHintLabel.isHidden = true
    }

    /// 머리 영역의 투명도 슬라이더 (OPA-01).
    ///
    /// 겉모습 패널에도 같은 값이 있지만, 투명도는 창을 보며 몇 번씩 다시 잡는 값이다.
    /// 팝오버를 열고 닫는 동안에는 창이 가려져 결과를 볼 수 없어, 손에 닿는 자리로 꺼냈다.
    private func buildOpacitySlider(into header: StickyHeaderView) {
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.minValue = MemoMeta.backgroundAlphaRange.lowerBound
        opacitySlider.maxValue = MemoMeta.backgroundAlphaRange.upperBound
        opacitySlider.doubleValue = meta.backgroundAlpha
        opacitySlider.isContinuous = true
        opacitySlider.controlSize = .mini
        opacitySlider.refusesFirstResponder = true
        opacitySlider.toolTip = "배경 투명도"
        opacitySlider.setAccessibilityLabel("배경 투명도")
        opacitySlider.target = self
        opacitySlider.action = #selector(opacitySliderChanged)
        header.addSubview(opacitySlider)

        let width = opacitySlider.widthAnchor.constraint(equalToConstant: 78)
        // 창이 좁아지면 슬라이더부터 양보한다. 버튼이 잘리는 것보다 낫다.
        width.priority = .defaultHigh
        opacitySliderWidthConstraint = width
        width.isActive = true
    }

    @objc private func opacitySliderChanged(_ sender: NSSlider) {
        let value = MemoMeta.clampBackgroundAlpha(sender.doubleValue)
        meta.backgroundAlpha = value
        rootView.apply(colorHex: meta.colorHex, backgroundAlpha: value)
        scheduleAlphaSave()
    }

    /// 끄는 동안에는 화면만 바꾸고, 손을 뗀 뒤에 한 번 저장한다.
    /// 슬라이더는 값이 이어서 쏟아지므로 그때마다 파일을 쓰면 디스크를 계속 두드린다.
    private func scheduleAlphaSave() {
        alphaSaveTimer?.invalidate()
        alphaSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveAlphaNow()
            }
        }
    }

    private func saveAlphaNow() {
        alphaSaveTimer?.invalidate()
        alphaSaveTimer = nil
        let value = meta.backgroundAlpha
        store?.updateMeta(id: memoID) { $0.backgroundAlpha = value }
    }

    // MARK: - 서식 막대 자리 (FMT-01, FMT-02)

    /// 머리 영역·서식 막대·본문의 세로 배치를 다시 잡는다.
    ///
    /// 막대는 위·아래를 오갈 수 있으므로, 자리와 얽힌 제약만 따로 모아 통째로 갈아 끼운다.
    private func layoutSections() {
        NSLayoutConstraint.deactivate(sectionConstraints)
        sectionConstraints = []

        guard let header else { return }

        // 접혀 있는 동안에는 막대도 배치에서 빼야 한다.
        // 감추기만 하면 제약이 그대로 남아, 창이 제목 줄 높이까지 줄어들지 않는다 (WIN-08).
        let position: FormatToolbarPosition = isCollapsed ? .hidden : toolbarPosition

        if position == .hidden {
            formatToolbar.removeFromSuperview()
        } else if formatToolbar.superview !== rootView {
            rootView.addSubview(formatToolbar, positioned: .below, relativeTo: resizeOverlay)
        }
        formatToolbar.position = position

        // 본문은 늘 머리 영역 아래에 있다. 달라지는 것은 좌우·위아래로 얼마를 내주느냐다.
        var constraints: [NSLayoutConstraint] = [
            // 위쪽(제목·아이콘, 또는 위에 붙은 서식 막대)과 본문 사이를 띄운다.
            // 붙어 있으면 본문 첫 줄이 버튼 줄의 일부처럼 읽힌다.
            scrollView.topAnchor.constraint(
                equalTo: position == .top ? formatToolbar.bottomAnchor : header.bottomAnchor,
                // 접혀 있을 때는 본문이 없으니 띄울 것도 없다. 띄우면 접힌 창이 그만큼 커진다.
                constant: isCollapsed ? 0 : Self.bodyTopSpacing
            ),
            // 창 가장자리 띠(크기 조절 자리)에는 본문도 스크롤 막대도 두지 않는다.
            // 겹치면 가장자리에 댄 마우스를 본문이 가로채 글자 커서로 바뀐다.
            scrollView.bottomAnchor.constraint(
                equalTo: position == .bottom ? formatToolbar.topAnchor : rootView.bottomAnchor,
                // 접혀 있을 때는 본문이 없으므로 여백도 두지 않는다. 두면 접힌 창이 그만큼 커진다.
                constant: position == .bottom ? -2 : (isCollapsed ? 0 : -ResizeOverlayView.edgeThickness)
            ),
            scrollView.leadingAnchor.constraint(
                equalTo: position == .left ? formatToolbar.trailingAnchor : rootView.leadingAnchor,
                constant: position == .left ? 2 : ResizeOverlayView.edgeThickness
            ),
            scrollView.trailingAnchor.constraint(
                equalTo: position == .right ? formatToolbar.leadingAnchor : rootView.trailingAnchor,
                constant: position == .right ? -2 : -ResizeOverlayView.edgeThickness
            ),
        ]

        switch position {
        case .hidden:
            break
        case .top:
            constraints += [
                formatToolbar.topAnchor.constraint(equalTo: header.bottomAnchor),
                formatToolbar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                formatToolbar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            ]
        case .bottom:
            // 바닥 가장자리는 크기 조절 자리다. 막대를 그 띠 위로 올려, 버튼과 겹치지 않게 한다.
            constraints += [
                formatToolbar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                formatToolbar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                formatToolbar.bottomAnchor.constraint(
                    equalTo: rootView.bottomAnchor,
                    constant: -ResizeOverlayView.reservedInset
                ),
            ]
        case .left, .right:
            // 세로 막대는 머리 영역 아래부터 창 바닥까지 선다.
            constraints += [
                formatToolbar.topAnchor.constraint(equalTo: header.bottomAnchor),
                formatToolbar.bottomAnchor.constraint(
                    equalTo: rootView.bottomAnchor,
                    constant: -ResizeOverlayView.reservedInset
                ),
                // 옆 가장자리도 크기 조절 자리라 그만큼 안으로 들인다.
                position == .left
                    ? formatToolbar.leadingAnchor.constraint(
                        equalTo: rootView.leadingAnchor,
                        constant: ResizeOverlayView.reservedInset - 4
                    )
                    : formatToolbar.trailingAnchor.constraint(
                        equalTo: rootView.trailingAnchor,
                        constant: -(ResizeOverlayView.reservedInset - 4)
                    ),
            ]
        }

        sectionConstraints = constraints
        NSLayoutConstraint.activate(constraints)
        // 이름표는 막대를 따라다닌다. 자리가 바뀌면 떠 있던 것을 지운다.
        hideToolbarHint()
    }

    /// 설정에서 막대 자리를 바꿨을 때 (FMT-02, SET-08).
    public func setToolbarPosition(_ position: FormatToolbarPosition) {
        guard position != toolbarPosition else { return }
        toolbarPosition = position
        layoutSections()
    }

    /// 서식 막대의 버튼에 마우스를 올린 것과 같은 경로를 태운다 (FMT-05).
    public func simulateToolbarHover(index: Int, isInside: Bool = true) {
        formatToolbar.simulateHover(index: index, isInside: isInside)
        // 창 단위 배치까지 돌려야 "제약이 창을 늘리는" 일이 드러난다.
        panel.layoutIfNeeded()
        rootView.layoutSubtreeIfNeeded()
    }

    /// 서식 막대의 버튼 개수.
    public var toolbarButtonCount: Int { formatToolbar.buttonCount }

    /// 지금 막대가 붙어 있는 자리.
    public var currentToolbarPosition: FormatToolbarPosition { toolbarPosition }

    /// 화면에 보이는 본문을 마크다운으로. 저장하지 않고 확인만 할 때 쓴다.
    public var currentBodyMarkdown: String { textView.currentMarkdown() }

    /// 서식 막대에서 온 명령. 단축키와 같은 길로 흘려보낸다.
    ///
    /// 버튼을 누르는 일은 눈으로만 확인하기 쉬운데, 그러면 고칠 때마다 놓치는 곳이 생긴다.
    /// 밖에서도 같은 경로를 부를 수 있게 열어 둔다.
    public func handleToolbarCommand(_ command: FormatToolbarView.Command) {
        // 버튼을 눌러도 글 쓰던 자리는 그대로여야 한다.
        panel.makeFirstResponder(textView)

        switch command {
        case .block(.tableRow):
            // 표는 한 줄의 서식이 아니라 여러 줄짜리 뼈대다 (MD-14).
            formatController?.insertTable()
        case .block(let block):
            formatController?.toggleBlock(block)
        case .inline(let tag):
            formatController?.toggleInlineStyle(tag)
        case .indent(let deeper):
            _ = formatController?.handleIndent(deeper: deeper)
        case .fontStep(let delta):
            onRequestFontStep?(delta)
        case .textColor(let hex):
            formatController?.setTextColor(hex)
        case .highlightColor(let hex):
            formatController?.setHighlightColor(hex)
        case .removeHighlight:
            formatController?.removeHighlight()
        }
        scheduleBodySave()
    }

    /// 배경과 텍스트에 각각 알파를 적용한다 (OPA-01/02).
    private func applyAppearance() {
        rootView.apply(colorHex: meta.colorHex, backgroundAlpha: meta.backgroundAlpha)
        // 배경이 밝은 파스텔이므로 다크 모드에서도 글자는 어두운 색이어야 읽힌다.
        textView.applyBaseTextColor(.black)
        textView.applyTextAlpha(meta.textAlpha)
    }

    public func show() {
        updateOpacitySliderVisibility()
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

    /// Tab을 눌렀을 때와 같은 경로를 태운다. 표의 칸 이동을 확인할 때 쓴다.
    public func simulateTabKey() {
        _ = formatController?.handleIndent(deeper: true)
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
        updateOpacitySliderVisibility()
        scheduleFrameSave()
    }

    /// 창 가장자리를 끌어 크기를 바꾸는 일은 대개 macOS가 직접 한다 (창이 크기 조절 가능으로 되어 있어서).
    /// 그때는 ResizeOverlayView가 끌기를 받지 못하므로, 크기 조절이 끝났다는 시스템 알림에서도
    /// 마지막 크기를 새 메모 기본값으로 넘긴다. 코드로 크기를 바꿀 때(접기·나열)는 이 알림이 오지 않는다.
    public func windowDidEndLiveResize(_ notification: Notification) {
        userDidResize(to: panel.frame.size)
    }

    /// 창이 좁으면 슬라이더를 감춘다. 버튼과 겹쳐 눌리는 것이 더 나쁘다.
    private func updateOpacitySliderVisibility() {
        opacitySlider.isHidden = panel.frame.width < 300
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
            textAlpha: meta.textAlpha,
            isPinned: meta.isPinned,
            onColorChange: { [weak self] hex in self?.setColor(hex) },
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
        opacitySlider.doubleValue = clamped
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
        updatePinImage()
        store?.updateMeta(id: memoID) { $0.isPinned = isPinned }
    }

    /// 핀 아이콘만 지금 상태에 맞춘다. 파일은 건드리지 않는다 —
    /// 글자 크기를 바꿀 때마다 메모의 수정 시각이 갱신되면 헛된 동기화 충돌이 생긴다.
    private func updatePinImage() {
        pinButton.image = NSImage(
            systemSymbolName: meta.isPinned ? "pin.fill" : "pin.slash",
            accessibilityDescription: "항상 위"
        )?.withSymbolConfiguration(.init(pointSize: Self.closeButtonSize(for: Self.chromeFontSize) * 0.8, weight: .regular))
    }

    // MARK: - 접기 (WIN-08)

    /// 제목 영역만 남기고 접는다. 다시 두 번 누르면 원래 높이로 돌아온다.
    public func toggleCollapsed() {
        let headerHeight = Self.headerHeight
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
        layoutSections()
        panel.setFrame(frame, display: true, animate: false)
        scrollView.isHidden = isCollapsed
        updateFoldButtonImage()
        saveFrameNow()
    }

    /// 창을 닫는다. 메모 파일은 남는다 (WIN-10).
    public func close() {
        formatController?.dismissPopups()
        titleChanged()
        saveBodyNow()
        saveFrameNow()
        saveAlphaNowIfPending()
        store?.setOpen(id: memoID, isOpen: false)
        meta.isOpen = false
        panel.orderOut(nil)
        onClose?(memoID)
    }

    /// 다른 기기에서 닫은 메모를 여기서도 닫는다 (SYNC-08).
    ///
    /// 파일에는 이미 "닫힘"으로 적혀 있으므로, 그 값을 다시 쓰지 않는다.
    /// 그렇지 않으면 수정 시각이 갱신돼 다음 동기화에서 헛된 충돌이 생긴다.
    public func closeWithoutMarkingClosed() {
        formatController?.dismissPopups()
        saveFrameNow()
        panel.orderOut(nil)
    }

    /// 동기화로 파일이 바뀌었을 때 화면 내용을 다시 읽는다 (SYNC-08).
    public func reloadBodyFromStore() {
        guard let document = store?.loadDocument(id: memoID) else { return }
        // 지금 쓰고 있는 중이면 건드리지 않는다. 사용자의 입력이 우선이다.
        guard !textView.isComposingText else { return }
        guard document.body != textView.currentMarkdown() else { return }

        meta = document.meta
        textView.loadMarkdown(document.body, theme: theme, textAlpha: meta.textAlpha)
        applyAppearance()
        // 다른 기기에서 제목을 고쳤을 수 있다. 지금 쓰고 있는 중이 아니면 맞춘다.
        if panel.firstResponder !== titleField.currentEditor() {
            titleField.stringValue = meta.title ?? ""
        }
    }

    /// 앱 종료 시 호출. 열림 상태는 유지한 채 내용만 확실히 저장한다 (WIN-06).
    public func flushBeforeTermination() {
        titleChanged()
        saveBodyNow()
        saveFrameNow()
        saveAlphaNowIfPending()
    }

    private func saveAlphaNowIfPending() {
        guard alphaSaveTimer != nil else { return }
        saveAlphaNow()
    }

    /// 환경설정에서 글꼴이나 크기를 바꿨을 때 열려 있는 창에 바로 반영한다 (TXT-02, TXT-03).
    public func applyTheme(_ newTheme: EditorTheme) {
        // 조합 중에 다시 그리면 입력하던 글자가 사라진다 (NFR-08).
        guard !textView.isComposingText else { return }
        theme = newTheme
        textView.reapplyTheme(newTheme, textAlpha: meta.textAlpha)
        formatController?.updateAppearance(theme: newTheme, textAlpha: meta.textAlpha)

        // 버튼·서식 막대·제목은 크기를 고정해 둔다 (chromeFontSize 참고). 제목 글꼴 종류만 다시 입힌다.
        applyTitleFont()
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

    /// 가장자리를 끌어 크기를 바꾼 것과 같은 결과를 낸다. 시험용.
    public func resizeAsUser(to size: NSSize) {
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)
        userDidResize(to: size)
    }

    public var isWindowVisible: Bool { panel.isVisible }

    public var isWindowCollapsed: Bool { isCollapsed }

    /// 창을 이 자리로 옮긴다. 리스트 창의 "창 나열"이 쓴다 (LST-06).
    public func setFrame(_ frame: NSRect) {
        panel.setFrame(frame, display: true, animate: false)
        if !isCollapsed {
            expandedHeight = frame.height
        }
        saveFrameNow()
    }

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
