import AppKit

/// 창 가장자리에서 크기를 조절한다 (WIN-07).
///
/// 프레임리스 창이라 시스템이 그려 주는 테두리가 없다. 그래서 가장자리 8곳을
/// 직접 잡아 끌 수 있게 만든다.
///
/// 이 뷰는 창 전체를 덮지만, 가장자리 밖의 점에서는 `hitTest`가 nil을 돌려주어
/// 마우스가 그대로 아래 편집기로 지나간다. 글을 쓰는 데 방해가 되지 않는다.
public final class ResizeOverlayView: NSView {
    /// 가장자리로 인정할 두께. 너무 좁으면 잡기 어렵고, 너무 넓으면 글자를 클릭할 수 없다.
    /// 6pt·8pt에서는 가장자리를 찾기가 어려워 넓혔다.
    public static let edgeThickness: CGFloat = 10

    /// 가장자리 띠 안쪽에 버튼을 두지 않기 위한 여백. 창 안의 버튼은 이만큼 떨어뜨려 둔다.
    /// 버튼이 띠에 걸치면 가장자리를 잡으려던 손이 버튼에 걸린다.
    public static let reservedInset: CGFloat = edgeThickness + 4

    /// 오른쪽 아래 손잡이. 가장자리를 더듬어 찾지 않아도 어디를 잡으면 되는지 보인다.
    private static let gripSize: CGFloat = 14

    private struct Edge: OptionSet {
        let rawValue: Int
        static let left = Edge(rawValue: 1 << 0)
        static let right = Edge(rawValue: 1 << 1)
        static let top = Edge(rawValue: 1 << 2)
        static let bottom = Edge(rawValue: 1 << 3)
    }

    private var activeEdge: Edge = []
    private var initialFrame: NSRect = .zero
    private var initialMouseLocation: NSPoint = .zero

    /// 사용자가 끌어서 크기를 바꾸고 손을 뗐을 때. 바뀐 창 크기를 넘긴다.
    public var onResizeEnded: ((NSSize) -> Void)?

    /// 창이 지나치게 작아지지 않게 한다.
    public var minimumSize = NSSize(width: 180, height: 120)

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // 부모 좌표계로 들어오므로 이 뷰 기준으로 바꿔서 판단한다.
        let local = convert(point, from: superview)
        return edge(at: local).isEmpty ? nil : self
    }

    private func edge(at point: NSPoint) -> Edge {
        var edge: Edge = []
        let thickness = Self.edgeThickness

        if point.x <= thickness { edge.insert(.left) }
        if point.x >= bounds.width - thickness { edge.insert(.right) }
        // 뷰 좌표는 아래가 0이다. 화면에서 보이는 위쪽은 y가 큰 쪽이다.
        if point.y <= thickness { edge.insert(.bottom) }
        if point.y >= bounds.height - thickness { edge.insert(.top) }

        // 손잡이는 가장자리보다 넓게 잡힌다.
        if point.x >= bounds.width - Self.gripSize, point.y <= Self.gripSize {
            edge = [.right, .bottom]
        }

        // 창 밖은 제외
        guard bounds.contains(point) else { return [] }
        return edge
    }

    // MARK: - 커서

    public override func resetCursorRects() {
        super.resetCursorRects()
        let thickness = Self.edgeThickness

        // 상하좌우
        addCursorRect(NSRect(x: 0, y: 0, width: thickness, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - thickness, y: 0, width: thickness, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: thickness), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.height - thickness, width: bounds.width, height: thickness), cursor: .resizeUpDown)

        // 모서리 네 곳. 대각선 커서는 최신 macOS에만 있어 확인 후 쓴다.
        let corners: [(NSRect, NSCursor)] = [
            (NSRect(x: 0, y: bounds.height - thickness, width: thickness, height: thickness), cornerCursor(topLeft: true)),
            (NSRect(x: bounds.width - thickness, y: bounds.height - thickness, width: thickness, height: thickness), cornerCursor(topLeft: false)),
            (NSRect(x: 0, y: 0, width: thickness, height: thickness), cornerCursor(topLeft: false)),
            (NSRect(x: bounds.width - thickness, y: 0, width: thickness, height: thickness), cornerCursor(topLeft: true)),
        ]
        for (rect, cursor) in corners {
            addCursorRect(rect, cursor: cursor)
        }
    }

    private func cornerCursor(topLeft: Bool) -> NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(
                position: topLeft ? .topLeft : .topRight,
                directions: .all
            )
        }
        return topLeft ? .resizeUpDown : .resizeLeftRight
    }

    // MARK: - 손잡이

    public override func draw(_ dirtyRect: NSRect) {
        // 오른쪽 아래에 사선 세 줄. 맥의 크기 조절 손잡이와 같은 꼴이다.
        let inset: CGFloat = 3
        let maxX = bounds.maxX - inset
        let minY = bounds.minY + inset
        let path = NSBezierPath()
        for step in 1...3 {
            let offset = CGFloat(step) * 3.5
            path.move(to: NSPoint(x: maxX - offset, y: minY))
            path.line(to: NSPoint(x: maxX, y: minY + offset))
        }
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.3).setStroke()
        path.stroke()
    }

    // MARK: - 창 이동과 겹치지 않게

    /// 이 창은 배경을 끌면 창이 움직인다(isMovableByWindowBackground).
    /// 투명한 뷰는 기본으로 "배경"으로 취급되어, 가장자리를 잡아 끌면 크기가 아니라 창 위치가 바뀌었다.
    /// 가장자리는 배경이 아니라고 알린다.
    public override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - 비활성 창에서도

    /// 메모 창은 대개 비활성이다. 첫 클릭을 창을 깨우는 데 쓰면 끌기가 시작되지 않는다.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 커서 영역(resetCursorRects)은 앱이 활성일 때만 동작한다.
    /// 비활성 창에서도 가장자리에 커서를 대면 모양이 바뀌도록 직접 추적한다.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    /// 지금 커서를 이 뷰가 바꿔 두었는지. 가장자리를 벗어날 때 한 번만 되돌린다.
    private var isShowingResizeCursor = false

    public override func mouseMoved(with event: NSEvent) {
        // 끄는 동안에는 커서를 그대로 둔다.
        guard activeEdge.isEmpty else { return }
        let edge = edge(at: convert(event.locationInWindow, from: nil))
        if let cursor = cursor(for: edge) {
            cursor.set()
            isShowingResizeCursor = true
        } else if isShowingResizeCursor {
            NSCursor.arrow.set()
            isShowingResizeCursor = false
        }
    }

    public override func mouseExited(with event: NSEvent) {
        guard activeEdge.isEmpty, isShowingResizeCursor else { return }
        NSCursor.arrow.set()
        isShowingResizeCursor = false
    }

    private func cursor(for edge: Edge) -> NSCursor? {
        switch edge {
        case [.left, .top], [.right, .bottom]: return cornerCursor(topLeft: true)
        case [.right, .top], [.left, .bottom]: return cornerCursor(topLeft: false)
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return nil
        }
    }

    // MARK: - 끌어서 조절

    public override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        activeEdge = edge(at: local)

        guard !activeEdge.isEmpty else {
            super.mouseDown(with: event)
            return
        }
        initialFrame = window.frame
        initialMouseLocation = NSEvent.mouseLocation
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !activeEdge.isEmpty, let window else {
            super.mouseDragged(with: event)
            return
        }

        let now = NSEvent.mouseLocation
        let deltaX = now.x - initialMouseLocation.x
        let deltaY = now.y - initialMouseLocation.y
        var frame = initialFrame

        if activeEdge.contains(.left) {
            let width = max(initialFrame.width - deltaX, minimumSize.width)
            frame.origin.x = initialFrame.maxX - width
            frame.size.width = width
        }
        if activeEdge.contains(.right) {
            frame.size.width = max(initialFrame.width + deltaX, minimumSize.width)
        }
        if activeEdge.contains(.bottom) {
            let height = max(initialFrame.height - deltaY, minimumSize.height)
            frame.origin.y = initialFrame.maxY - height
            frame.size.height = height
        }
        if activeEdge.contains(.top) {
            frame.size.height = max(initialFrame.height + deltaY, minimumSize.height)
        }

        window.setFrame(frame, display: true)
    }

    public override func mouseUp(with event: NSEvent) {
        let wasResizing = !activeEdge.isEmpty
        activeEdge = []
        // 가장자리를 눌렀다 떼기만 한 것은 크기 조절이 아니다.
        guard wasResizing, let window, window.frame.size != initialFrame.size else { return }
        onResizeEnded?(window.frame.size)
    }
}
