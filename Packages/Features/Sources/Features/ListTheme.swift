import AppKit
import SwiftUI

/// 목록 창에서 공통으로 쓰는 동적 색과 치수
public enum ListTheme {
    private static func color(_ name: String, _ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("목록.\(name)"), dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        }))
    }
    public static let windowBg = color("창", 0xF6F6F7, 0x18191B)
    public static let sidebarBg = color("사이드바", 0xEFEFF1, 0x1E1F22)
    public static let boardBg = color("보드", 0xEEEFF1, 0x1B1C1F)
    public static let card = color("카드", 0xFFFFFF, 0x26272A)
    public static let ink = color("먹색", 0x1C1D20, 0xEDEDEF)
    public static let text2 = color("본문", 0x5B5E66, 0xA9ABB2)
    public static let muted = color("보조", 0x6B6E76, 0x8C8F96)
    public static let hairline = color("경계", 0x1C1D20, 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.08)
    public static let chipBg = color("칩", 0xF1F2F4, 0x303135)
    public static let related = color("관련", 0x9A9DA4, 0x74777E)
    public static let lime = color("라임", 0xD4F53C, 0xD4F53C)
    public static let boardDot = color("격자", 0x1C1D20, 0xFFFFFF, lightAlpha: 0.13, darkAlpha: 0.10)
    public static let track = color("보기", 0xE8E9EC, 0x2A2B2E)
    public static let flowBg = color("흐름", 0xFAFAFB, 0x2C2D31)
    public static let sidebarWidth: CGFloat = 232
}

struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var selected = false
    func body(content: Content) -> some View {
        content.background(ListTheme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? ListTheme.ink : ListTheme.hairline, lineWidth: selected ? 2 : 1))
            .shadow(color: scheme == .dark ? .clear : ListTheme.ink.opacity(0.05), radius: 1, y: 1)
            .shadow(color: scheme == .dark ? .clear : ListTheme.ink.opacity(0.07), radius: 24, y: 8)
    }
}

struct LimeDot: View {
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(ListTheme.lime).overlay(Circle().stroke(ListTheme.ink.opacity(size == 8 ? 0.22 : 1), lineWidth: size == 8 ? 1 : 1.5))
            .frame(width: size, height: size)
    }
}

struct FlowSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 2.5
        path.addEllipse(in: CGRect(x: rect.minX, y: rect.midY - r, width: r * 2, height: r * 2))
        path.move(to: CGPoint(x: rect.minX + r * 2, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - r * 2, y: rect.midY))
        path.addEllipse(in: CGRect(x: rect.maxX - r * 2, y: rect.midY - r, width: r * 2, height: r * 2))
        return path
    }
}

struct PlaceholderSurface: View {
    var body: some View {
        Canvas { context, size in
            var lines = Path()
            for x in stride(from: -size.height, through: size.width, by: 10) {
                lines.move(to: CGPoint(x: x, y: size.height))
                lines.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(lines, with: .color(ListTheme.ink.opacity(0.06)), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: NSColor(srgbRed: 166/255, green: 169/255, blue: 176/255, alpha: 1)), style: StrokeStyle(lineWidth: 2, dash: [6, 6])))
    }
}
