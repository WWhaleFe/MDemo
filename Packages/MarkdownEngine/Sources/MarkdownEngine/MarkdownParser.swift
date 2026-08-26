import Foundation

/// 마크다운 문자열을 서식 표현으로 되돌린다. 파일을 열 때 쓴다.
///
/// `MarkdownSerializer`와 짝을 이루며, 왕복해도 내용이 변하지 않아야 한다.
/// 지원 범위는 명세가 허용한 것만이다 — 표준 마크다운 + `==형광==` (DOC-04).
public enum MarkdownParser {
    public static func parse(_ markdown: String) -> [StyledLine] {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map(parseLine)
    }

    public static func parseLine(_ line: String) -> StyledLine {
        let (block, content) = parseBlock(line)
        return StyledLine(block: block, spans: parseInline(content))
    }

    // MARK: - 블록

    private static func parseBlock(_ line: String) -> (BlockStyle, String) {
        let indentLevel = countIndent(line)
        let trimmed = String(line.drop { $0 == " " || $0 == "\t" })

        if trimmed == "---" {
            return (.divider, "")
        }

        // 제목: # ~ ###### (들여쓰기 없음)
        if indentLevel == 0, trimmed.hasPrefix("#") {
            var level = 0
            var index = trimmed.startIndex
            while index < trimmed.endIndex, trimmed[index] == "#", level < 6 {
                level += 1
                index = trimmed.index(after: index)
            }
            if index < trimmed.endIndex, trimmed[index] == " " {
                return (.heading(level: level), String(trimmed[trimmed.index(after: index)...]))
            }
        }

        // 체크박스가 글머리 기호보다 먼저다 — "- [ ]"는 "- "로도 읽히기 때문이다.
        for (marker, checked) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] {
            if trimmed.hasPrefix(marker) {
                return (.checkbox(indent: indentLevel, checked: checked), String(trimmed.dropFirst(marker.count)))
            }
        }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return (.bullet(indent: indentLevel), String(trimmed.dropFirst(2)))
        }

        if let (number, rest) = parseOrderedMarker(trimmed) {
            return (.ordered(indent: indentLevel, number: number), rest)
        }

        if trimmed.hasPrefix("> ") {
            return (.quote, String(trimmed.dropFirst(2)))
        }

        return (.paragraph, line)
    }

    /// 들여쓰기 한 단계 = 공백 2칸. 탭 하나도 한 단계로 센다.
    private static func countIndent(_ line: String) -> Int {
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 }
            else if character == "\t" { spaces += 2 }
            else { break }
        }
        return spaces / 2
    }

    private static func parseOrderedMarker(_ text: String) -> (number: Int, rest: String)? {
        var digits = ""
        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber {
            digits.append(text[index])
            index = text.index(after: index)
        }
        guard !digits.isEmpty, let number = Int(digits), index < text.endIndex, text[index] == "." else {
            return nil
        }
        let afterDot = text.index(after: index)
        guard afterDot < text.endIndex, text[afterDot] == " " else { return nil }
        return (number, String(text[text.index(after: afterDot)...]))
    }

    // MARK: - 인라인

    /// 바깥쪽 기호부터 벗겨 낸다. 직렬화가 감싼 순서(굵게 → 기울임 → 취소선 → 형광 → 코드)의 역순이다.
    private static func parseInline(_ text: String) -> [StyledSpan] {
        guard !text.isEmpty else { return [] }
        var spans: [StyledSpan] = []
        appendSpans(from: Array(text), styles: [], into: &spans)
        return mergeAdjacent(spans)
    }

    /// 긴 기호를 먼저 검사한다. `***`(굵게+기울임)를 `**`로 잡으면
    /// 남은 `*` 하나가 짝을 잃어 저장할 때마다 기호가 늘어난다.
    private static let delimiters: [(marker: [Character], style: InlineStyleTag)] = [
        (Array("***"), [.bold, .italic]),
        (Array("**"), .bold),
        (Array("~~"), .strikethrough),
        (Array("=="), .highlight),
        (Array("`"), .code),
        (Array("*"), .italic),
    ]

    private static func appendSpans(
        from characters: [Character],
        styles: InlineStyleTag,
        into spans: inout [StyledSpan]
    ) {
        var index = 0
        var plain: [Character] = []

        func flushPlain() {
            if !plain.isEmpty {
                spans.append(StyledSpan(text: String(plain), styles: styles))
                plain = []
            }
        }

        outer: while index < characters.count {
            for (marker, style) in delimiters {
                // 코드 구간 안에서는 다른 기호를 서식으로 보지 않는다.
                if styles.contains(.code) && style != .code { continue }
                guard !styles.contains(style) else { continue }
                guard matches(characters, at: index, marker: marker) else { continue }

                if let closing = findClosing(characters, from: index + marker.count, marker: marker) {
                    flushPlain()
                    let inner = Array(characters[(index + marker.count)..<closing])
                    appendSpans(from: inner, styles: styles.union(style), into: &spans)
                    index = closing + marker.count
                    continue outer
                }
            }
            plain.append(characters[index])
            index += 1
        }
        flushPlain()
    }

    private static func matches(_ characters: [Character], at index: Int, marker: [Character]) -> Bool {
        guard index + marker.count <= characters.count else { return false }
        return Array(characters[index..<(index + marker.count)]) == marker
    }

    /// 닫는 기호 위치를 찾는다. 내용이 비어 있으면 서식으로 보지 않는다.
    private static func findClosing(_ characters: [Character], from start: Int, marker: [Character]) -> Int? {
        var index = start
        while index + marker.count <= characters.count {
            if matches(characters, at: index, marker: marker) {
                return index > start ? index : nil
            }
            index += 1
        }
        return nil
    }

    /// 같은 서식이 이어지는 구간은 하나로 합친다. 저장 결과가 안정되게 유지하기 위해서다.
    private static func mergeAdjacent(_ spans: [StyledSpan]) -> [StyledSpan] {
        var merged: [StyledSpan] = []
        for span in spans where !span.text.isEmpty {
            if var last = merged.last, last.styles == span.styles {
                last.text += span.text
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}
