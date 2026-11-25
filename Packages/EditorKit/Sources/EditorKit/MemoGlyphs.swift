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

    /// 암호 단추 기호 (24 상자, 시안 B + D).
    /// 일반 메모: 고리가 열린 자물쇠 + 빈 점 (누르면 잠근다).
    /// 잠긴 메모: 고리가 닫힌 자물쇠 + 라임 점 (앱 아이콘의 라임 점과 같은 색).
    /// 라임을 칠해야 해서 틀 이미지(template)가 아니다. 선 색은 `ink`로 받는다.
    public static func lock(locked: Bool, pointSize: CGFloat, ink: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: pointSize / 24)
            transform.concat()
            ink.set()
            stroke(NSBezierPath(roundedRect: NSRect(x: 5, y: 10.5, width: 14, height: 10), xRadius: 2.5, yRadius: 2.5))
            let shackle = NSBezierPath()
            shackle.move(to: NSPoint(x: 8, y: 10.5))
            if locked {
                shackle.line(to: NSPoint(x: 8, y: 8))
                shackle.appendArc(withCenter: NSPoint(x: 12, y: 8), radius: 4, startAngle: 180, endAngle: 0, clockwise: false)
                shackle.line(to: NSPoint(x: 16, y: 10.5))
            } else {
                // 오른쪽 다리를 들어 올린 열린 고리.
                shackle.line(to: NSPoint(x: 8, y: 7.5))
                shackle.appendArc(withCenter: NSPoint(x: 12, y: 7.5), radius: 4, startAngle: 180, endAngle: 335, clockwise: false)
            }
            stroke(shackle)
            if locked {
                lockLime.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12 - 2.4, y: 15.5 - 2.4, width: 4.8, height: 4.8)).fill()
            } else {
                ink.set()
                let dot = NSBezierPath(ovalIn: NSRect(x: 12 - 1.6, y: 15.5 - 1.6, width: 3.2, height: 3.2))
                dot.lineWidth = 1.8
                dot.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 앱 아이콘의 라임 점 색.
    public static let lockLime = NSColor(srgbRed: 0xD4 / 255, green: 0xF5 / 255, blue: 0x3C / 255, alpha: 1)

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
