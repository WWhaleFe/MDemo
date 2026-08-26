import AppKit
import EditorKit
import MemoCore

/// 메모 한 개 = 창 한 개. 이 컨트롤러가 창의 수명을 쥔다.
///
/// 메모리 원칙(§4-5): 창이 닫히면 컨트롤러가 통째로 해제되고 본문도 함께 사라진다.
/// 목록에 남는 것은 메타데이터와 미리보기뿐이다.
@MainActor
public final class StickyWindowController {
    public let memoID: MemoID
    public private(set) var meta: MemoMeta

    private let panel: StickyPanel
    private let rootView: StickyRootView
    private let textView: MemoTextView
    private let scrollView: NSScrollView

    /// 사용자가 창을 닫았을 때 호출된다. 레지스트리가 이 신호로 컨트롤러를 해제한다.
    public var onClose: ((MemoID) -> Void)?

    private static let headerHeight: CGFloat = 26

    public init(meta: MemoMeta, frame: NSRect) {
        self.memoID = meta.id
        self.meta = meta
        self.panel = StickyPanel(contentRect: frame)
        self.rootView = StickyRootView(frame: NSRect(origin: .zero, size: frame.size))
        self.scrollView = NSScrollView()
        self.textView = MemoTextView.makeTextKit1(frame: NSRect(origin: .zero, size: frame.size))

        buildViewHierarchy()
        applyAppearance()
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
        closeButton.contentTintColor = NSColor.labelColor.withAlphaComponent(0.35)
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

    @objc private func closeButtonTapped() {
        close()
    }

    /// 창을 닫는다. 메모 파일은 남는다 (WIN-10).
    public func close() {
        panel.orderOut(nil)
        meta.isOpen = false
        onClose?(memoID)
    }

    public func setHidden(_ hidden: Bool) {
        if hidden {
            panel.orderOut(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    /// 현재 창 위치와 크기. M2에서 device-state.json에 저장한다 (SYNC-07).
    public var currentFrame: NSRect { panel.frame }
}
