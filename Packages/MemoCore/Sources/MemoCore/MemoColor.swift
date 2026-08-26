import Foundation

/// 배경색 프리셋 8가지 (WIN-11). UI 프레임워크에 의존하지 않도록 16진수 문자열로 보관한다.
public struct MemoColor: Hashable, Sendable {
    public let name: String
    public let hex: String

    public init(name: String, hex: String) {
        self.name = name
        self.hex = hex
    }

    public static let presets: [MemoColor] = [
        MemoColor(name: "노랑", hex: "#FFF3B0"),
        MemoColor(name: "복숭아", hex: "#FFD9C0"),
        MemoColor(name: "분홍", hex: "#FFD1DC"),
        MemoColor(name: "연보라", hex: "#E4D4F4"),
        MemoColor(name: "하늘", hex: "#CDE7F6"),
        MemoColor(name: "민트", hex: "#CDEFE3"),
        MemoColor(name: "연두", hex: "#E2F0C4"),
        MemoColor(name: "회색", hex: "#E6E6E6"),
    ]

    /// "#RRGGBB" 문자열을 0~1 범위의 RGB 성분으로 변환한다. 형식이 어긋나면 nil.
    public static func components(fromHex hex: String) -> (red: Double, green: Double, blue: Double)? {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
