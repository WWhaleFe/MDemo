import Foundation

/// 입력 중 자동 서식 변환 규칙 (MD-01 ~ MD-13).
///
/// **확장 지점**: 새 마크다운 문법을 추가할 때는 이 프로토콜을 채택한 타입을 하나 만들어
/// `InputRuleSet`에 등록한다. 에디터 본체(EditorKit)는 절대 수정하지 않는다.
public protocol InputRule: Sendable {
    /// 스펙 ID를 그대로 사용한다 (예: "MD-01").
    var id: String { get }

    /// 한 줄을 검사해 변환이 필요하면 결과를 돌려주고, 아니면 nil.
    func match(line: String, caretOffset: Int) -> InputRuleMatch?
}

/// 변환 결과. 에디터는 이 값을 받아 텍스트 저장소에 반영한다.
public struct InputRuleMatch: Hashable, Sendable {
    /// 원본 줄에서 치환할 범위 (UTF-16 오프셋).
    public var range: Range<Int>
    /// 치환할 문자열. 마크다운 기호를 숨기는 경우 빈 문자열이 된다.
    public var replacement: String
    /// 적용할 서식.
    public var style: InlineStyle

    public init(range: Range<Int>, replacement: String, style: InlineStyle) {
        self.range = range
        self.replacement = replacement
        self.style = style
    }
}

/// 에디터가 실제 텍스트 속성으로 옮길 서식 종류. UI 프레임워크 타입을 쓰지 않는다.
public enum InlineStyle: Hashable, Sendable {
    case heading(level: Int)
    case bold
    case italic
    case strikethrough
    case highlight
    case inlineCode
    case bulletList
    case orderedList
    case checkbox(checked: Bool)
    case quote
    case divider
    case codeBlock
}

/// 규칙 모음. 등록 순서대로 검사한다.
public struct InputRuleSet: Sendable {
    public private(set) var rules: [any InputRule]

    public init(rules: [any InputRule] = []) {
        self.rules = rules
    }

    public mutating func register(_ rule: any InputRule) {
        rules.append(rule)
    }

    public func firstMatch(line: String, caretOffset: Int) -> InputRuleMatch? {
        for rule in rules {
            if let match = rule.match(line: line, caretOffset: caretOffset) {
                return match
            }
        }
        return nil
    }

    /// M1에서 MD-01 ~ MD-07 규칙을 여기에 채운다.
    public static let standard = InputRuleSet()
}
