import AppKit

/// 맨 위 줄과 메뉴에서 같은 좌표로 그리는 단색 기호.
public enum MemoGlyphs {
    public static func airDrop(pointSize: CGFloat) -> NSImage {
        template(pointSize: pointSize) {
            NSBezierPath(ovalIn: NSRect(x: 9.6, y: 10.1, width: 4.8, height: 4.8)).fill()
            for radius: CGFloat in [6, 9.6] {
                let ring = NSBezierPath()
                ring.appendArc(withCenter: NSPoint(x: 12, y: 12.5), radius: radius,
                               startAngle: 122, endAngle: 418, clockwise: false)
                stroke(ring)
            }
        }
    }

    public static func exportImage(pointSize: CGFloat) -> NSImage {
        template(pointSize: pointSize) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 12, y: 9.5))
            path.line(to: NSPoint(x: 5.5, y: 9.5))
            path.curve(to: NSPoint(x: 4, y: 11), controlPoint1: NSPoint(x: 4.672, y: 9.5), controlPoint2: NSPoint(x: 4, y: 10.172))
            path.line(to: NSPoint(x: 4, y: 19.5))
            path.curve(to: NSPoint(x: 5.5, y: 21), controlPoint1: NSPoint(x: 4, y: 20.328), controlPoint2: NSPoint(x: 4.672, y: 21))
            path.line(to: NSPoint(x: 14, y: 21))
            path.curve(to: NSPoint(x: 15.5, y: 19.5), controlPoint1: NSPoint(x: 14.828, y: 21), controlPoint2: NSPoint(x: 15.5, y: 20.328))
            path.line(to: NSPoint(x: 15.5, y: 16))
            for (start, end) in [(NSPoint(x: 7, y: 14.5), NSPoint(x: 11, y: 14.5)),
                                 (NSPoint(x: 7, y: 17.5), NSPoint(x: 12, y: 17.5)),
                                 (NSPoint(x: 18.5, y: 13), NSPoint(x: 18.5, y: 2.5))] {
                path.move(to: start)
                path.line(to: end)
            }
            path.move(to: NSPoint(x: 14, y: 7))
            path.line(to: NSPoint(x: 18.5, y: 2.5))
            path.line(to: NSPoint(x: 23, y: 7))
            stroke(path)
        }
    }

    private static func stroke(_ path: NSBezierPath) {
        // 24 상자 좌표를 단추 크기로 줄여 그리므로 선도 함께 가늘어진다. SF Symbols 보통 굵기와 맞도록 조금 굵게 잡는다.
        path.lineWidth = 2.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func template(pointSize: CGFloat, draw: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: pointSize / 24)
            transform.concat()
            NSColor.black.set()
            draw()
            return true
        }
        image.isTemplate = true
        return image
    }
}
