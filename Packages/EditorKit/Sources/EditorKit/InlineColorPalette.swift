import AppKit
import MarkdownEngine
import MemoCore

/// 글자 색·형광펜 색 고르기에 쓰는 색 목록과, 색 표기 → 화면 색 변환.
///
/// 아무 색이나 고르게 두면 파스텔 메모 배경 위에서 읽히지 않는 색이 나오기 쉽다.
/// 메모 배경 위에서 읽히는 것을 확인한 색만 내놓는다.
public enum InlineColorPalette {
    public struct Entry: Equatable, Sendable {
        public let name: String
        /// "#RRGGBB". 형광펜의 기본 노랑은 nil — 파일에 `==`로 남는다.
        public let hex: String?
    }

    /// 글자 색. 첫 칸은 "기본"(색 지우기)이라 목록에 넣지 않고 메뉴에서 따로 붙인다.
    public static let textColors: [Entry] = [
        Entry(name: "빨강", hex: "#D93025"),
        Entry(name: "주황", hex: "#E8710A"),
        Entry(name: "초록", hex: "#188038"),
        Entry(name: "파랑", hex: "#1A73E8"),
        Entry(name: "보라", hex: "#8E24AA"),
        Entry(name: "회색", hex: "#80868B"),
    ]

    public static let highlightColors: [Entry] = [
        Entry(name: "노랑", hex: nil),
        Entry(name: "초록", hex: "#A8E6A1"),
        Entry(name: "파랑", hex: "#A7D3FF"),
        Entry(name: "분홍", hex: "#FFB3D1"),
        Entry(name: "보라", hex: "#D7B8FF"),
        Entry(name: "주황", hex: "#FFCC99"),
    ]

    /// 형광펜 칠의 진하기. 글씨가 묻히지 않게 반쯤 비친다.
    static let highlightAlpha: CGFloat = 0.55

    /// 기본 노랑. 예전부터 쓰던 색이라 그대로 둔다.
    static let defaultHighlight = NSColor.systemYellow.withAlphaComponent(0.45)

    public static func color(fromHex hex: String) -> NSColor? {
        guard let normalized = InlineColor.normalized(hex),
              let rgb = MemoColor.components(fromHex: normalized)
        else { return nil }
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// 형광펜 칠 색. nil이면 기본 노랑.
    public static func highlightBackground(hex: String?) -> NSColor {
        guard let hex, let color = color(fromHex: hex) else { return defaultHighlight }
        return color.withAlphaComponent(highlightAlpha)
    }

    /// 글자 색. 색이 없으면 테마 색을 쓰고, 텍스트 알파는 어느 쪽이든 곱한다 (OPA-02).
    static func foreground(hex: String?, theme: EditorTheme, alpha: Double) -> NSColor {
        let base = hex.flatMap(color(fromHex:)) ?? theme.textColor
        return base.withAlphaComponent(alpha)
    }
}
