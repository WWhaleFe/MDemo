import AppKit

/// 비활성 창에서도 바로 누를 수 있고, 마우스를 올리면 옅은 바탕을 그린다.
class TopBarButton: NSButton {
    static let hoverColor = NSColor.black.withAlphaComponent(0.06)
    private var hovered = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            Self.hoverColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}
