import Foundation

/// 줄 앞머리 기호로 블록을 결정하는 규칙들 (MD-01 ~ MD-04).
///
/// 공통 동작: 기호를 입력하고 공백을 치는 순간 서식이 적용되고 기호는 화면에서 사라진다.
/// 저장할 때는 기호가 그대로 복원되므로 파일은 표준 마크다운을 유지한다 (DOC-01).

/// 앞쪽 공백을 세어 들여쓰기 단계를 구한다. 공백 2칸 또는 탭 1개가 한 단계다.
private func indentLevel(of text: String) -> (level: Int, contentStart: Int) {
    var spaces = 0
    var consumed = 0
    for character in text {
        if character == " " { spaces += 1; consumed += 1 }
        else if character == "\t" { spaces += 2; consumed += 1 }
        else { break }
    }
    return (spaces / 2, consumed)
}

/// `# ` ~ `###### ` → 제목 1~6 (MD-01)
public struct HeadingRule: InputRule {
    public let id = "MD-01"

    public init() {}

    public func match(_ context: InputRuleContext) -> InputRuleMatch? {
        guard context.block == .paragraph else { return nil }

        let characters = Array(context.content)
        var level = 0
        while level < characters.count, characters[level] == "#", level < 6 {
            level += 1
        }
        guard level > 0, level < characters.count, characters[level] == " " else { return nil }

        let markerLength = level + 1
        // 커서가 기호 바로 뒤에 있을 때만 변환한다. 이미 쓴 줄을 건드리지 않기 위해서다.
        guard context.caretOffset == markerLength else { return nil }
        return InputRuleMatch(range: 0..<markerLength, replacement: "", outcome: .block(.heading(level: level)))
    }
}

/// `- ` 또는 `* ` → 글머리 기호 목록 (MD-02)
public struct BulletListRule: InputRule {
    public let id = "MD-02"

    public init() {}

    public func match(_ context: InputRuleContext) -> InputRuleMatch? {
        guard context.block == .paragraph else { return nil }

        let (level, contentStart) = indentLevel(of: context.content)
        let rest = String(context.content.dropFirst(contentStart))
        guard rest.hasPrefix("- ") || rest.hasPrefix("* ") else { return nil }
        // 체크박스는 별도 규칙이 처리한다.
        guard !rest.hasPrefix("- [") else { return nil }

        let markerRange = contentStart..<(contentStart + 2)
        guard context.caretOffset == markerRange.upperBound else { return nil }
        return InputRuleMatch(range: markerRange, replacement: "", outcome: .block(.bullet(indent: level)))
    }
}

/// `1. ` → 번호 목록 (MD-03)
public struct OrderedListRule: InputRule {
    public let id = "MD-03"

    public init() {}

    public func match(_ context: InputRuleContext) -> InputRuleMatch? {
        guard context.block == .paragraph else { return nil }

        let (level, contentStart) = indentLevel(of: context.content)
        let rest = Array(context.content.dropFirst(contentStart))

        var digits = 0
        while digits < rest.count, rest[digits].isNumber {
            digits += 1
        }
        guard digits > 0,
              digits + 1 < rest.count,
              rest[digits] == ".",
              rest[digits + 1] == " ",
              let number = Int(String(rest[0..<digits]))
        else { return nil }

        let markerLength = digits + 2
        let markerRange = contentStart..<(contentStart + markerLength)
        guard context.caretOffset == markerRange.upperBound else { return nil }
        return InputRuleMatch(range: markerRange, replacement: "", outcome: .block(.ordered(indent: level, number: number)))
    }
}

/// 체크박스 (MD-04). 저장 시 표준 문법을 유지한다 (CHK-05).
///
/// 두 갈래로 들어올 수 있다:
/// 1. 문단에서 `- [ ] `를 통째로 입력
/// 2. 이미 글머리 목록인 줄에서 `[ ] `만 입력 — `- `가 이미 목록으로 바뀌었기 때문에
///    실제 사용에서는 이쪽이 훨씬 흔하다
public struct CheckboxRule: InputRule {
    public let id = "MD-04"

    public init() {}

    /// `[]`처럼 공백을 생략한 형태도 받아준다. 손이 빠른 사람이 자주 이렇게 친다.
    private static let uncheckedMarkers = ["[ ] ", "[] "]
    private static let checkedMarkers = ["[x] ", "[X] "]

    public func match(_ context: InputRuleContext) -> InputRuleMatch? {
        switch context.block {
        case .paragraph:
            return matchFromParagraph(context)
        case .bullet(let indent):
            return matchFromBullet(context, indent: indent)
        default:
            return nil
        }
    }

    private func matchFromParagraph(_ context: InputRuleContext) -> InputRuleMatch? {
        let (level, contentStart) = indentLevel(of: context.content)
        let rest = String(context.content.dropFirst(contentStart))

        for marker in Self.uncheckedMarkers.map({ "- " + $0 }) where rest.hasPrefix(marker) {
            let range = contentStart..<(contentStart + marker.count)
            guard context.caretOffset == range.upperBound else { return nil }
            return InputRuleMatch(range: range, replacement: "", outcome: .block(.checkbox(indent: level, checked: false)))
        }
        for marker in Self.checkedMarkers.map({ "- " + $0 }) where rest.hasPrefix(marker) {
            let range = contentStart..<(contentStart + marker.count)
            guard context.caretOffset == range.upperBound else { return nil }
            return InputRuleMatch(range: range, replacement: "", outcome: .block(.checkbox(indent: level, checked: true)))
        }
        return nil
    }

    /// 이미 글머리 목록인 줄에서 `[ ] `를 치면 체크박스로 바뀐다.
    private func matchFromBullet(_ context: InputRuleContext, indent: Int) -> InputRuleMatch? {
        for marker in Self.uncheckedMarkers where context.content.hasPrefix(marker) {
            guard context.caretOffset == marker.count else { return nil }
            return InputRuleMatch(range: 0..<marker.count, replacement: "", outcome: .block(.checkbox(indent: indent, checked: false)))
        }
        for marker in Self.checkedMarkers where context.content.hasPrefix(marker) {
            guard context.caretOffset == marker.count else { return nil }
            return InputRuleMatch(range: 0..<marker.count, replacement: "", outcome: .block(.checkbox(indent: indent, checked: true)))
        }
        return nil
    }
}
