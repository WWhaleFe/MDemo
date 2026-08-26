import Foundation

/// 짝을 이루는 기호로 감싼 구간에 서식을 입히는 규칙들 (MD-05 ~ MD-09).
///
/// 닫는 기호를 입력하는 순간 변환된다. 여는 기호까지 되짚어 찾아야 하므로
/// 공통 로직을 `PairedDelimiterRule`에 두고 기호와 스타일만 갈아 끼운다.
public struct PairedDelimiterRule: InputRule {
    public let id: String
    private let delimiter: String
    private let style: InlineStyle

    public init(id: String, delimiter: String, style: InlineStyle) {
        self.id = id
        self.delimiter = delimiter
        self.style = style
    }

    public func match(line: String, caretOffset: Int) -> InputRuleMatch? {
        let characters = Array(line)
        let delimiterCharacters = Array(delimiter)
        let length = delimiterCharacters.count

        // 커서 바로 앞이 닫는 기호여야 한다.
        guard caretOffset >= length * 2 + 1, caretOffset <= characters.count else { return nil }
        let closingStart = caretOffset - length
        guard Array(characters[closingStart..<caretOffset]) == delimiterCharacters else { return nil }

        // 여는 기호를 뒤에서부터 찾는다.
        var openingStart = closingStart - length
        while openingStart >= 0 {
            if Array(characters[openingStart..<(openingStart + length)]) == delimiterCharacters {
                let contentRange = (openingStart + length)..<closingStart
                // 빈 내용(`****`)은 변환하지 않는다.
                guard !contentRange.isEmpty else { return nil }
                let content = String(characters[contentRange])
                // 기호만 있고 내용이 공백뿐이면 사용자가 아직 입력 중이다.
                guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

                return InputRuleMatch(
                    range: openingStart..<caretOffset,
                    replacement: content,
                    style: style
                )
            }
            openingStart -= 1
        }
        return nil
    }
}

public extension PairedDelimiterRule {
    /// `**텍스트**` → 굵게 (MD-05)
    static var bold: PairedDelimiterRule {
        PairedDelimiterRule(id: "MD-05", delimiter: "**", style: .bold)
    }

    /// `*텍스트*` → 기울임 (MD-06). 굵게 규칙보다 뒤에 등록해야 `**`가 먼저 잡힌다.
    static var italic: PairedDelimiterRule {
        PairedDelimiterRule(id: "MD-06", delimiter: "*", style: .italic)
    }

    /// `~~텍스트~~` → 취소선 (MD-07)
    static var strikethrough: PairedDelimiterRule {
        PairedDelimiterRule(id: "MD-07", delimiter: "~~", style: .strikethrough)
    }

    /// `==텍스트==` → 형광색 (MD-08). 표준 마크다운은 아니지만 명세가 허용한 확장이다 (DOC-04).
    static var highlight: PairedDelimiterRule {
        PairedDelimiterRule(id: "MD-08", delimiter: "==", style: .highlight)
    }

    /// `` `텍스트` `` → 인라인 코드 (MD-09)
    static var inlineCode: PairedDelimiterRule {
        PairedDelimiterRule(id: "MD-09", delimiter: "`", style: .inlineCode)
    }
}

public extension InputRuleSet {
    /// M1에서 지원하는 규칙 모음.
    ///
    /// 등록 순서가 곧 우선순위다. `**`(굵게)를 `*`(기울임)보다 먼저 두어야
    /// 굵게 입력이 기울임으로 잘못 잡히지 않는다.
    static var m1: InputRuleSet {
        InputRuleSet(rules: [
            HeadingRule(),
            CheckboxRule(),
            BulletListRule(),
            OrderedListRule(),
            PairedDelimiterRule.bold,
            PairedDelimiterRule.strikethrough,
            PairedDelimiterRule.highlight,
            PairedDelimiterRule.inlineCode,
            PairedDelimiterRule.italic,
        ])
    }
}
