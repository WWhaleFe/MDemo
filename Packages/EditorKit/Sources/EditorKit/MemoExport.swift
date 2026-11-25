import AppKit

/// 메모를 이미지로 내보낼 때의 옵션과 크기 계산.
///
/// 크기 계산은 화면 없이 시험할 수 있게 순수 값으로 둔다.
public struct MemoExportOptions: Equatable, Sendable {
    /// 메모 색 배경을 깐다. 끄면 투명 배경이다.
    public var usesMemoColor = true
    /// 아래에 날짜와 앱 이름을 넣는다.
    public var showsFooter = true
    /// 흐름 줄(이전 · 다음 메모)을 본문 아래에 함께 그린다.
    public var includesFlowStrip = false
    /// 배율은 1배 또는 2배다. 예전에 고른 3배도 2배로 읽는다.
    private var storedScale = 2
    public var scale: Int {
        get { min(max(storedScale, 1), 2) }
        set { storedScale = min(max(newValue, 1), 2) }
    }

    public static let scales = [1, 2]
    /// 아래 표시 줄 높이(포인트).
    public static let footerHeight: CGFloat = 28
    /// 한 변의 픽셀 한도. 이보다 크면 만들지 않는다 (메모리 보호).
    public static let maxPixelSide = 16_384

    public init(usesMemoColor: Bool = true, showsFooter: Bool = true, includesFlowStrip: Bool = false, scale: Int = 2) {
        self.usesMemoColor = usesMemoColor
        self.showsFooter = showsFooter
        self.includesFlowStrip = includesFlowStrip
        self.scale = scale
    }

    /// 결과 그림의 크기.
    public struct Layout: Equatable, Sendable {
        /// 포인트 크기(1배일 때의 픽셀 수).
        public var pointSize: CGSize
        public var pixelWidth: Int
        public var pixelHeight: Int
        /// 본문 · 흐름 줄 · 표시 줄의 높이(포인트).
        public var contentHeight: CGFloat
        public var flowHeight: CGFloat
        public var footerHeight: CGFloat

        /// "1200 × 3400 px" 꼴의 안내 문구.
        public var sizeText: String { "\(pixelWidth) × \(pixelHeight) px" }
        public var isTooLarge: Bool {
            max(pixelWidth, pixelHeight) > MemoExportOptions.maxPixelSide
        }
    }

    /// - Parameters:
    ///   - contentSize: 본문 전체의 포인트 크기(가로는 창의 본문 폭, 세로는 글 전체 높이).
    ///   - flowHeight: 흐름 줄 높이. 흐름에 든 메모가 아니면 0.
    public func layout(contentSize: CGSize, flowHeight: CGFloat) -> Layout {
        let flow = includesFlowStrip ? max(0, flowHeight) : 0
        let footer = showsFooter ? Self.footerHeight : 0
        let width = max(1, contentSize.width)
        let height = max(1, contentSize.height) + flow + footer
        return Layout(
            pointSize: CGSize(width: width, height: height),
            pixelWidth: Int((width * CGFloat(scale)).rounded(.up)),
            pixelHeight: Int((height * CGFloat(scale)).rounded(.up)),
            contentHeight: max(1, contentSize.height),
            flowHeight: flow,
            footerHeight: footer
        )
    }
}

extension MemoTextView {
    /// 글 전체가 차지하는 크기(포인트). 가로는 지금 본문 폭이다.
    public func exportContentSize() -> CGSize {
        guard let layoutManager, let textContainer else { return CGSize(width: bounds.width, height: 1) }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: bounds.width, height: ceil(used.maxY + textContainerOrigin.y * 2))
    }

    /// 서식이 입혀진 본문을 투명 배경 그림으로 그린다. 커서와 고름 표시는 뺀다.
    func renderContent(scale: Int) -> NSBitmapImageRep? {
        let size = exportContentSize()
        guard size.width >= 1, size.height >= 1 else { return nil }
        let rect = NSRect(origin: .zero, size: size)

        // 고른 글과 이미지 테두리가 그림에 들어가지 않게 잠시 선택을 푼다.
        let savedSelection = selectedRange()
        let wasFirstResponder = window?.firstResponder === self
        setSelectedRange(NSRange(location: 0, length: 0))
        defer {
            setSelectedRange(savedSelection)
            if wasFirstResponder { needsDisplay = true }
        }
        return Self.render(view: self, rect: rect, scale: scale)
    }

    static func render(view: NSView, rect: NSRect, scale: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((rect.width * CGFloat(scale)).rounded(.up)),
            pixelsHigh: Int((rect.height * CGFloat(scale)).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = rect.size
        view.cacheDisplay(in: rect, to: rep)
        return rep
    }
}

/// 메모 한 장을 PNG로 그린다 (본문 + 선택한 흐름 줄 + 표시 줄).
@MainActor
public enum MemoExportRenderer {
    /// - Parameters:
    ///   - textView: 메모 본문 뷰. 편집 중인 표시를 그대로 쓴다.
    ///   - flowStrip: 흐름 줄 뷰. 옵션이 켜져 있고 높이가 있을 때만 그린다.
    ///   - backgroundColor: 메모 색(투명도 없이).
    ///   - footerText: 표시 줄 글자 (예: "2026. 11. 25. · MDemo").
    public static func render(
        textView: MemoTextView,
        flowStrip: NSView?,
        options: MemoExportOptions,
        backgroundColor: NSColor,
        footerText: String
    ) -> NSBitmapImageRep? {
        let flowHeight = flowStrip?.bounds.height ?? 0
        let layout = options.layout(contentSize: textView.exportContentSize(), flowHeight: flowHeight)
        guard !layout.isTooLarge, let content = textView.renderContent(scale: options.scale) else { return nil }

        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: layout.pixelWidth, pixelsHigh: layout.pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        output.size = layout.pointSize
        guard let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let full = NSRect(origin: .zero, size: layout.pointSize)
        NSColor.clear.setFill()
        full.fill(using: .copy)
        if options.usesMemoColor {
            backgroundColor.withAlphaComponent(1).setFill()
            full.fill()
        }

        // 위에서 아래로: 본문, 흐름 줄, 표시 줄. 좌표 원점은 왼쪽 아래다.
        var cursorTop = layout.pointSize.height
        let contentRect = NSRect(x: 0, y: cursorTop - layout.contentHeight, width: layout.pointSize.width, height: layout.contentHeight)
        drawOver(content, in: contentRect)
        cursorTop -= layout.contentHeight

        if layout.flowHeight > 0, let flowStrip,
           let flowRep = MemoTextView.render(view: flowStrip, rect: flowStrip.bounds, scale: options.scale) {
            let width = layout.pointSize.width
            drawOver(flowRep, in: NSRect(x: 0, y: cursorTop - layout.flowHeight, width: min(width, flowStrip.bounds.width), height: layout.flowHeight))
            cursorTop -= layout.flowHeight
        }

        if layout.footerHeight > 0 {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.black.withAlphaComponent(0.45),
            ]
            let text = footerText as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: layout.pointSize.width - size.width - 12, y: (layout.footerHeight - size.height) / 2),
                withAttributes: attributes
            )
        }
        return output
    }

    /// 이미 칠한 배경 위에 겹쳐 그린다. 투명한 곳은 배경이 비친다.
    private static func drawOver(_ rep: NSBitmapImageRep, in rect: NSRect) {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    public static func pngData(_ rep: NSBitmapImageRep) -> Data? {
        rep.representation(using: .png, properties: [:])
    }
}
