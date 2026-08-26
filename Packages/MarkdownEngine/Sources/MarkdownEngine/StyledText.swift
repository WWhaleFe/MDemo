import Foundation

/// 서식이 적용된 문서의 중간 표현.
///
/// 에디터는 마크다운 기호를 숨기고 서식만 보여주므로(MD-01 "기호는 숨김"),
/// 화면의 텍스트와 파일의 마크다운은 서로 다르다. 이 타입이 둘 사이의 다리다.
///
/// `NSAttributedString`을 쓰지 않는 이유는 이 계층을 UI에서 떼어내
/// 변환 규칙을 순수 로직으로 시험하기 위해서다 (iOS 확장에서도 그대로 쓴다).

/// 줄 단위 블록 서식.
public enum BlockStyle: Hashable, Sendable {
    case paragraph
    case heading(level: Int)
    case bullet(indent: Int)
    case ordered(indent: Int, number: Int)
    case checkbox(indent: Int, checked: Bool)
    case quote
    case divider

    /// 목록 들여쓰기 단계 (Tab/Shift+Tab, KEY-08).
    public var indent: Int {
        switch self {
        case .bullet(let indent), .ordered(let indent, _), .checkbox(let indent, _):
            return indent
        default:
            return 0
        }
    }
}

/// 글자 단위 서식. 여러 개가 겹칠 수 있다.
public struct InlineStyleTag: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = InlineStyleTag(rawValue: 1 << 0)
    public static let italic = InlineStyleTag(rawValue: 1 << 1)
    public static let strikethrough = InlineStyleTag(rawValue: 1 << 2)
    public static let highlight = InlineStyleTag(rawValue: 1 << 3)
    public static let code = InlineStyleTag(rawValue: 1 << 4)
}

/// 같은 서식이 이어지는 구간.
public struct StyledSpan: Hashable, Sendable {
    public var text: String
    public var styles: InlineStyleTag

    public init(text: String, styles: InlineStyleTag = []) {
        self.text = text
        self.styles = styles
    }
}

/// 한 줄.
public struct StyledLine: Hashable, Sendable {
    public var block: BlockStyle
    public var spans: [StyledSpan]

    public init(block: BlockStyle = .paragraph, spans: [StyledSpan]) {
        self.block = block
        self.spans = spans
    }

    public init(block: BlockStyle = .paragraph, text: String) {
        self.init(block: block, spans: text.isEmpty ? [] : [StyledSpan(text: text)])
    }

    /// 서식을 뺀 순수 텍스트 (화면에 보이는 내용).
    public var plainText: String {
        spans.map(\.text).joined()
    }
}
