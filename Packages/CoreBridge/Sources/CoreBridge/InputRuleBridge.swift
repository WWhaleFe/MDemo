// 입력 규칙(Rust mdemo-markdown)의 얇은 래퍼. 생성된 UniFFI 타입은 이 계층 밖으로 내보내지 않는다.
// 위치는 모두 Character(확장 문자소) 단위이고, Swift `InputRuleSet.m1.firstMatch(line:caretOffset:)`와 같은 결과를 낸다.

/// 입력 규칙이 돌려주는 변환 결과.
public struct CoreInputRuleMatch: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case heading(level: Int)
        case bullet(indent: Int)
        case ordered(indent: Int, number: Int)
        case checkbox(indent: Int, checked: Bool)
        case codeBlock
        /// 글자 서식 비트 집합(굵게 1, 기울임 2, 취소선 4, 형광 8, 코드 16).
        case inline(styles: Int)
    }

    /// `line`에서 지울 구간 (Character 단위).
    public var range: Range<Int>
    public var replacement: String
    public var outcome: Outcome

    public init(range: Range<Int>, replacement: String, outcome: Outcome) {
        self.range = range
        self.replacement = replacement
        self.outcome = outcome
    }
}

public enum InputRuleBridge {
    /// 문단 상태의 줄에서 첫 번째로 걸리는 규칙. 없으면 nil.
    public static func firstMatch(line: String, caretOffset: Int) -> CoreInputRuleMatch? {
        guard caretOffset >= 0, caretOffset <= Int(UInt32.max),
              let match = inputRuleFirstMatch(line: line, caretOffset: UInt32(caretOffset))
        else { return nil }
        let outcome: CoreInputRuleMatch.Outcome
        switch match.outcome {
        case .heading(let level): outcome = .heading(level: Int(level))
        case .bullet(let indent): outcome = .bullet(indent: Int(indent))
        case .ordered(let indent, let number): outcome = .ordered(indent: Int(indent), number: Int(number))
        case .checkbox(let indent, let checked): outcome = .checkbox(indent: Int(indent), checked: checked)
        case .codeBlock: outcome = .codeBlock
        case .inline(let styles): outcome = .inline(styles: Int(styles))
        }
        return CoreInputRuleMatch(range: Int(match.rangeStart)..<Int(match.rangeEnd), replacement: match.replacement, outcome: outcome)
    }
}
