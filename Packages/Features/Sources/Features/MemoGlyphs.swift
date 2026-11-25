import SwiftUI

/// 아래쪽을 쐐기 모양으로 비운 두 고리와 가운데 점.
struct AirDropGlyph: View {
    var body: some View {
        ZStack {
            Path { path in
                for radius: CGFloat in [6, 9.6] {
                    path.move(to: CGPoint(x: 12 + radius * cos(122 * .pi / 180), y: 12.5 + radius * sin(122 * .pi / 180)))
                    path.addArc(center: CGPoint(x: 12, y: 12.5), radius: radius,
                                startAngle: .degrees(122), endAngle: .degrees(418), clockwise: false)
                }
            }.stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            Circle().frame(width: 4.8, height: 4.8).position(x: 12, y: 12.5)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

/// 작은 메모 카드에서 오른쪽 위로 나가는 큰 화살표.
struct ExportImageGlyph: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 12, y: 9.5))
            path.addLine(to: CGPoint(x: 5.5, y: 9.5))
            path.addCurve(to: CGPoint(x: 4, y: 11), control1: CGPoint(x: 4.672, y: 9.5), control2: CGPoint(x: 4, y: 10.172))
            path.addLine(to: CGPoint(x: 4, y: 19.5))
            path.addCurve(to: CGPoint(x: 5.5, y: 21), control1: CGPoint(x: 4, y: 20.328), control2: CGPoint(x: 4.672, y: 21))
            path.addLine(to: CGPoint(x: 14, y: 21))
            path.addCurve(to: CGPoint(x: 15.5, y: 19.5), control1: CGPoint(x: 14.828, y: 21), control2: CGPoint(x: 15.5, y: 20.328))
            path.addLine(to: CGPoint(x: 15.5, y: 16))
            for (start, end) in [(CGPoint(x: 7, y: 14.5), CGPoint(x: 11, y: 14.5)),
                                 (CGPoint(x: 7, y: 17.5), CGPoint(x: 12, y: 17.5)),
                                 (CGPoint(x: 18.5, y: 13), CGPoint(x: 18.5, y: 2.5))] {
                path.move(to: start)
                path.addLine(to: end)
            }
            path.move(to: CGPoint(x: 14, y: 7))
            path.addLine(to: CGPoint(x: 18.5, y: 2.5))
            path.addLine(to: CGPoint(x: 23, y: 7))
        }
        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

/// 암호 단추 기호. AppKit 쪽 `MemoGlyphs.lock`과 같은 좌표 (24 상자, 시안 B + D).
struct LockGlyph: View {
    var locked: Bool
    var body: some View {
        ZStack {
            Path { path in
                path.addRoundedRect(in: CGRect(x: 5, y: 10.5, width: 14, height: 10), cornerSize: CGSize(width: 2.5, height: 2.5))
                path.move(to: CGPoint(x: 8, y: 10.5))
                if locked {
                    path.addLine(to: CGPoint(x: 8, y: 8))
                    path.addArc(center: CGPoint(x: 12, y: 8), radius: 4, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                    path.addLine(to: CGPoint(x: 16, y: 10.5))
                } else {
                    path.addLine(to: CGPoint(x: 8, y: 7.5))
                    path.addArc(center: CGPoint(x: 12, y: 7.5), radius: 4, startAngle: .degrees(180), endAngle: .degrees(335), clockwise: false)
                }
                if !locked { path.addEllipse(in: CGRect(x: 10.4, y: 13.9, width: 3.2, height: 3.2)) }
            }.stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            if locked {
                Circle().fill(ListTheme.lime)
                    .frame(width: 4.8, height: 4.8).position(x: 12, y: 15.5)
            }
        }
        .frame(width: 24, height: 24)
    }
}

/// 목록 · 카드의 잠긴 메모 표시. 글자 높이에 맞춘 작은 `LockGlyph`.
struct LockedMark: View {
    var body: some View {
        LockGlyph(locked: true).scaleEffect(14 / 24).frame(width: 14, height: 14)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            .accessibilityLabel("잠긴 메모")
    }
}

/// 노션에 보내기 기호. AppKit 쪽 `MemoGlyphs.notion`과 같은 좌표 (24 상자).
struct NotionGlyph: View {
    var body: some View {
        Path { path in
            path.addRoundedRect(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17), cornerSize: CGSize(width: 3.5, height: 3.5))
            path.move(to: CGPoint(x: 9, y: 16))
            path.addLine(to: CGPoint(x: 9, y: 8))
            path.addLine(to: CGPoint(x: 15, y: 16))
            path.addLine(to: CGPoint(x: 15, y: 8))
        }
        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        .frame(width: 24, height: 24)
    }
}

