import Foundation

/// 마크다운 문자열을 서식 표현으로 되돌린다. 파일을 열 때 쓴다.
///
/// `MarkdownSerializer`와 짝을 이루며, 왕복해도 내용이 변하지 않아야 한다.
/// 지원 범위는 명세가 허용한 것만이다 — 표준 마크다운 + `==형광==` (DOC-04).
public enum MarkdownParser {
    /// 코드 박스의 울타리 기호 (MD-10).
    public static let codeFence = "```"

    public static func parse(_ markdown: String) -> [StyledLine] {
        var lines: [StyledLine] = []
        var insideCodeBlock = false

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            // 울타리 줄 자체는 화면에 남기지 않는다. 마크다운 기호는 숨긴다는 원칙 그대로다 (MD-01).
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix(codeFence) {
                insideCodeBlock.toggle()
                continue
            }
            if insideCodeBlock {
                // 코드 안의 `*`나 `#`는 서식이 아니라 코드다. 인라인 해석을 하지 않는다.
                lines.append(StyledLine(block: .codeBlock, spans: raw.isEmpty ? [] : [StyledSpan(text: raw)]))
                continue
            }
            // 표의 구분 줄은 문법이지 내용이 아니다. 화면에서 빼고 저장할 때 다시 만든다 (MD-14).
            if MarkdownTable.isSeparatorRow(raw) {
                continue
            }
            lines.append(parseLine(raw))
        }
        return lines
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

        // 표는 세로줄이 곧 내용이다. 기호를 벗기지 않고 줄 전체를 그대로 둔다 (MD-14).
        if MarkdownTable.isRow(trimmed) {
            return (.tableRow, trimmed)
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
        appendSpans(from: Array(text), format: StyledSpan(text: ""), into: &spans)
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

    /// `format`은 바깥에서 물려받은 서식이다. 글자는 비어 있고 서식만 쓴다.
    private static func appendSpans(
        from characters: [Character],
        format: StyledSpan,
        into spans: inout [StyledSpan]
    ) {
        let styles = format.styles
        var index = 0
        var plain: [Character] = []

        func flushPlain() {
            if !plain.isEmpty {
                var span = format
                span.text = String(plain)
                spans.append(span)
                plain = []
            }
        }

        outer: while index < characters.count {
            // 색 태그 (<span style="color:…">, <mark style="background:…">). 코드 안에서는 글자일 뿐이다.
            if !styles.contains(.code), characters[index] == "<",
               let tag = matchColorTag(characters, at: index),
               let closing = findClosing(characters, from: index + tag.openingLength, marker: Array(tag.closing)) {
                flushPlain()
                var inner = format
                if tag.isHighlight {
                    inner.styles.insert(.highlight)
                    inner.highlightColor = tag.hex
                } else {
                    inner.textColor = tag.hex
                }
                let content = Array(characters[(index + tag.openingLength)..<closing])
                appendSpans(from: content, format: inner, into: &spans)
                index = closing + tag.closing.count
                continue outer
            }

            for (marker, style) in delimiters {
                // 코드 구간 안에서는 다른 기호를 서식으로 보지 않는다.
                if styles.contains(.code) && style != .code { continue }
                guard !styles.contains(style) else { continue }
                guard matches(characters, at: index, marker: marker) else { continue }

                if let closing = findClosing(characters, from: index + marker.count, marker: marker) {
                    flushPlain()
                    let inner = Array(characters[(index + marker.count)..<closing])
                    var innerFormat = format
                    innerFormat.styles = styles.union(style)
                    appendSpans(from: inner, format: innerFormat, into: &spans)
                    index = closing + marker.count
                    continue outer
                }
            }
            plain.append(characters[index])
            index += 1
        }
        flushPlain()
    }

    private struct ColorTag {
        let isHighlight: Bool
        let hex: String
        let openingLength: Int
        let closing: String
    }

    /// 여는 색 태그를 읽는다. 앱이 쓰는 꼴 말고도, 다른 도구가 흔히 쓰는 꼴
    /// (`background-color:`, 따옴표 종류, 공백, 소문자)까지는 받아 준다.
    private static let colorTagPattern = try! NSRegularExpression(
        pattern: #"^<(span|mark)\s+style\s*=\s*["']\s*(color|background|background-color)\s*:\s*(#?[0-9A-Fa-f]{6})\s*;?\s*["']\s*>"#
    )

    private static func matchColorTag(_ characters: [Character], at index: Int) -> ColorTag? {
        // 태그는 길지 않다. 줄 끝까지 넘기지 않고 앞부분만 본다.
        let window = String(characters[index..<min(characters.count, index + 64)])
        let range = NSRange(window.startIndex..., in: window)
        guard let match = colorTagPattern.firstMatch(in: window, range: range),
              let tagRange = Range(match.range(at: 1), in: window),
              let propertyRange = Range(match.range(at: 2), in: window),
              let hexRange = Range(match.range(at: 3), in: window),
              let wholeRange = Range(match.range, in: window),
              let hex = InlineColor.normalized(String(window[hexRange]))
        else { return nil }

        let tag = String(window[tagRange])
        let isHighlight = tag == "mark"
        // <span style="color">만 글자 색, <mark style="background">만 형광펜으로 본다.
        let property = String(window[propertyRange])
        guard isHighlight == property.hasPrefix("background") else { return nil }

        return ColorTag(
            isHighlight: isHighlight,
            hex: hex,
            openingLength: window[wholeRange].count,
            closing: "</\(tag)>"
        )
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
            if var last = merged.last, last.hasSameFormat(as: span) {
                last.text += span.text
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}
