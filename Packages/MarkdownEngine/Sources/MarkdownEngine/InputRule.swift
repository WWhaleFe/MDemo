import Foundation

/// 규칙이 판단에 쓰는 정보.
///
/// `content`는 화면 표식(`• `, `☐ `)을 뺀 순수 내용이고, `block`은 그 줄에 이미 걸린 블록 서식이다.
/// 규칙이 현재 블록을 알아야 하는 이유: `- `를 치면 글머리 목록이 되는데,
/// 그 상태에서 `[ ] `를 이어 치면 체크박스로 바뀌어야 한다. 블록을 모르면 이 전환을 할 수 없다.
public struct InputRuleContext: Hashable, Sendable {
    public var content: String
    /// `content` 기준 커서 위치 (Character 단위).
    public var caretOffset: Int
    public var block: BlockStyle

    public init(content: String, caretOffset: Int, block: BlockStyle = .paragraph) {
        self.content = content
        self.caretOffset = caretOffset
        self.block = block
    }
}

/// 변환 결과.
public enum InputRuleOutcome: Hashable, Sendable {
    /// 줄 전체를 이 블록 서식으로 바꾼다.
    case block(BlockStyle)
    /// 기호를 지운 자리의 글자에 이 서식을 입힌다.
    case inline(InlineStyleTag)
}

/// 입력 중 자동 서식 변환 규칙 (MD-01 ~ MD-13).
///
/// **확장 지점**: 새 마크다운 문법을 추가할 때는 이 프로토콜을 채택한 타입을 하나 만들어
/// `InputRuleSet`에 등록한다. 에디터 본체(EditorKit)는 절대 수정하지 않는다.
public protocol InputRule: Sendable {
    /// 스펙 ID를 그대로 사용한다 (예: "MD-01").
    var id: String { get }

    /// 변환이 필요하면 결과를 돌려주고, 아니면 nil.
    func match(_ context: InputRuleContext) -> InputRuleMatch?
}

/// 에디터가 실제 텍스트에 반영할 변경 내용.
public struct InputRuleMatch: Hashable, Sendable {
    /// `content`에서 지울 구간 (Character 단위).
    public var range: Range<Int>
    /// 그 자리에 넣을 문자열. 기호를 숨기는 경우 빈 문자열이 된다.
    public var replacement: String
    public var outcome: InputRuleOutcome

    public init(range: Range<Int>, replacement: String, outcome: InputRuleOutcome) {
        self.range = range
        self.replacement = replacement
        self.outcome = outcome
    }
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

    public func firstMatch(_ context: InputRuleContext) -> InputRuleMatch? {
        for rule in rules {
            if let match = rule.match(context) {
                return match
            }
        }
        return nil
    }

    /// 편의용 — 문단 상태의 줄을 검사한다.
    public func firstMatch(line: String, caretOffset: Int) -> InputRuleMatch? {
        firstMatch(InputRuleContext(content: line, caretOffset: caretOffset))
    }
}
