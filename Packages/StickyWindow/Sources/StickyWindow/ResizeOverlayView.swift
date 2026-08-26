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
    private static let edgeThickness: CGFloat = 6

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
        activeEdge = []
    }
}
