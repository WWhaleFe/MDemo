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
    /// 코드 박스 (MD-10). 한 줄씩 이 서식을 달고, 저장할 때 ``` 울타리로 묶는다.
    case codeBlock
    /// 표의 한 줄 (MD-14). 구분 줄은 화면에 두지 않고 저장할 때 만들어 넣는다.
    case tableRow

    /// 목록 들여쓰기 단계 (Tab/Shift+Tab, KEY-08).
    public var indent: Int {
        switch self {
        case .bullet(let indent), .ordered(let indent, _), .checkbox(let indent, _):
            return indent
        default:
            return 0
        }
    }

    /// Tab으로 단계를 조절할 수 있는 종류인가.
    /// 코드 박스 안의 Tab은 들여쓰기가 아니라 코드의 일부다.
    public var allowsIndentChange: Bool {
        switch self {
        case .bullet, .ordered, .checkbox: return true
        default: return false
        }
    }
}

/// 번호 목록의 단계별 표식 (MD-03).
///
/// 단계가 달라져도 전부 `1.`로 보이면 어느 단계인지 알 수 없다.
/// 그래서 화면에서는 단계마다 다른 꼴을 쓴다 — 숫자 → 영문 → 로마자, 그 뒤로는 되풀이한다.
/// 파일에는 표준 마크다운대로 늘 `1.` 꼴로 적는다 (DOC-01, DOC-04).
public enum OrderedListMarker {
    public enum Style: Int, CaseIterable, Sendable {
        case number
        case letter
        case roman
    }

    public static func style(forIndent indent: Int) -> Style {
        let all = Style.allCases
        return all[max(0, indent) % all.count]
    }

    /// 화면에 보일 표식. 점은 포함하고 뒤 공백은 포함하지 않는다.
    public static func text(number: Int, indent: Int) -> String {
        let value = max(1, number)
        switch style(forIndent: indent) {
        case .number:
            return "\(value)."
        case .letter:
            return "\(letters(value))."
        case .roman:
            return "\(roman(value))."
        }
    }

    /// 1 → a, 26 → z, 27 → aa. 엑셀 열 이름과 같은 규칙이다.
    public static func letters(_ number: Int) -> String {
        var remaining = max(1, number)
        var result = ""
        while remaining > 0 {
            let index = (remaining - 1) % 26
            result = String(UnicodeScalar(UInt8(97 + index))) + result
            remaining = (remaining - 1) / 26
        }
        return result
    }

    /// 1 → i, 4 → iv, 9 → ix. 목록이 그렇게까지 길어질 일은 없지만 규칙은 온전히 둔다.
    public static func roman(_ number: Int) -> String {
        let table: [(value: Int, symbol: String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var remaining = max(1, number)
        var result = ""
        for (value, symbol) in table {
            while remaining >= value {
                result += symbol
                remaining -= value
            }
        }
        return result
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
    /// 글자 색 ("#RRGGBB"). nil이면 테마의 기본 글자색.
    public var textColor: String?
    /// 형광펜 색 ("#RRGGBB"). `styles`에 `.highlight`가 있을 때만 뜻이 있고, nil이면 기본 노랑이다.
    public var highlightColor: String?

    public init(text: String, styles: InlineStyleTag = [], textColor: String? = nil, highlightColor: String? = nil) {
        self.text = text
        self.styles = styles
        self.textColor = InlineColor.normalized(textColor)
        self.highlightColor = styles.contains(.highlight) ? InlineColor.normalized(highlightColor) : nil
    }

    /// 글자를 뺀 서식만 같은지. 이어 붙일 수 있는 구간인지 가릴 때 쓴다.
    public func hasSameFormat(as other: StyledSpan) -> Bool {
        styles == other.styles && textColor == other.textColor && highlightColor == other.highlightColor
    }
}

/// 글자 색·형광펜 색 표기 ("#RRGGBB").
///
/// 표준 마크다운에는 색 문법이 없어 HTML 태그로 남긴다 (DOC-04 확장).
/// 다른 마크다운 도구에서도 대부분 색이 그대로 보이고, 못 읽는 도구에서도 글자는 남는다.
public enum InlineColor {
    /// "#abc123" → "#ABC123". 형식이 틀리면 nil.
    public static func normalized(_ hex: String?) -> String? {
        guard var value = hex?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if !value.hasPrefix("#") { value = "#" + value }
        let digits = value.dropFirst()
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return value.uppercased()
    }

    /// 글자 색 태그.
    static func textOpening(_ hex: String) -> String { "<span style=\"color:\(hex)\">" }
    static let textClosing = "</span>"

    /// 형광펜 색 태그. 기본 노랑은 `==`로 쓰고, 다른 색일 때만 이 태그를 쓴다.
    static func highlightOpening(_ hex: String) -> String { "<mark style=\"background:\(hex)\">" }
    static let highlightClosing = "</mark>"
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
