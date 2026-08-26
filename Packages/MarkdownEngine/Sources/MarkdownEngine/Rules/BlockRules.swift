import Foundation

/// 줄 앞머리 기호로 블록을 결정하는 규칙들 (MD-01 ~ MD-04).
///
/// 공통 동작: 기호를 입력하고 공백을 치는 순간 서식이 적용되고 기호는 화면에서 사라진다.
/// 저장할 때는 기호가 그대로 복원되므로 파일은 표준 마크다운을 유지한다 (DOC-01).

/// `# ` ~ `###### ` → 제목 1~6 (MD-01)
public struct HeadingRule: InputRule {
    public let id = "MD-01"

    public init() {}

    public func match(line: String, caretOffset: Int) -> InputRuleMatch? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }

        let markerLength = level + 1
        // 커서가 기호 바로 뒤에 있을 때만 변환한다. 이미 쓴 줄을 건드리지 않기 위해서다.
        guard caretOffset == markerLength else { return nil }
        return InputRuleMatch(range: 0..<markerLength, replacement: "", style: .heading(level: level))
    }
}

/// `- ` 또는 `* ` → 글머리 기호 목록 (MD-02)
public struct BulletListRule: InputRule {
    public let id = "MD-02"

    public init() {}

    public func match(line: String, caretOffset: Int) -> InputRuleMatch? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let indentLength = line.count - trimmed.count
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
        // 체크박스는 별도 규칙이 처리한다.
        guard !trimmed.hasPrefix("- [") else { return nil }

        let markerRange = indentLength..<(indentLength + 2)
        guard caretOffset == markerRange.upperBound else { return nil }
        return InputRuleMatch(range: markerRange, replacement: "", style: .bulletList)
    }
}

/// `1. ` → 번호 목록 (MD-03)
public struct OrderedListRule: InputRule {
    public let id = "MD-03"

    public init() {}

    public func match(line: String, caretOffset: Int) -> InputRuleMatch? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let indentLength = line.count - trimmed.count

        var digits = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber {
            digits += 1
            index = trimmed.index(after: index)
        }
        guard digits > 0, index < trimmed.endIndex, trimmed[index] == "." else { return nil }

        let afterDot = trimmed.index(after: index)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }

        let markerLength = digits + 2
        let markerRange = indentLength..<(indentLength + markerLength)
        guard caretOffset == markerRange.upperBound else { return nil }
        return InputRuleMatch(range: markerRange, replacement: "", style: .orderedList)
    }
}

/// `- [ ] ` → 체크박스 (MD-04). 저장 시 표준 문법을 유지한다 (CHK-05).
public struct CheckboxRule: InputRule {
    public let id = "MD-04"

    public init() {}

    public func match(line: String, caretOffset: Int) -> InputRuleMatch? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let indentLength = line.count - trimmed.count

        let unchecked = "- [ ] "
        let checkedVariants = ["- [x] ", "- [X] "]

        if trimmed.hasPrefix(unchecked) {
            let markerRange = indentLength..<(indentLength + unchecked.count)
            guard caretOffset == markerRange.upperBound else { return nil }
            return InputRuleMatch(range: markerRange, replacement: "", style: .checkbox(checked: false))
        }
        for variant in checkedVariants where trimmed.hasPrefix(variant) {
            let markerRange = indentLength..<(indentLength + variant.count)
            guard caretOffset == markerRange.upperBound else { return nil }
            return InputRuleMatch(range: markerRange, replacement: "", style: .checkbox(checked: true))
        }
        return nil
    }
}
