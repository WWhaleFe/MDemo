import Foundation

/// 다른 앱에서 붙여 넣은 글을 이 앱의 마크다운 해석기가 읽을 수 있게 다듬는다.
///
/// 노션 · 다른 편집기가 클립보드에 넣는 마크다운은 파일 형식과 조금씩 다르다.
/// - 들여쓰기 단위가 제각각이다 (노션·표준은 4칸, 탭, 이 앱 파일은 2칸).
/// - 목록 기호가 `•` · `◦` · `▪`처럼 글자로 들어오기도 하고, 체크박스가 `☐`/`☑`로 오기도 한다.
/// - 줄바꿈이 \r\n이거나, 공백 대신 줄바꿈 없는 공백(NBSP)이 섞여 있다.
/// 파일 해석기를 느슨하게 만들면 저장된 메모를 잘못 읽을 위험이 있어, 붙여넣기에서만 손본다.
public enum PastedMarkdown {
    public static func parse(_ text: String) -> [StyledLine] {
        MarkdownParser.parse(normalize(text))
    }

    /// 파일 해석기가 바로 읽을 수 있는 꼴로 바꾼다. 코드 박스 안은 건드리지 않는다.
    public static func normalize(_ text: String) -> String {
        let raw = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        var lines = raw.components(separatedBy: "\n")
        // 클립보드 끝의 빈 줄 하나는 내용이 아니다. 남기면 붙여 넣을 때마다 빈 줄이 하나씩 생긴다.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 {
            lines.removeLast()
        }

        let unit = indentUnit(of: lines)
        var insideCode = false
        return lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(MarkdownParser.codeFence) {
                insideCode.toggle()
                return line.trimmingCharacters(in: .whitespaces)
            }
            if insideCode { return line }

            let (spaces, body) = splitIndent(line)
            let marked = normalizeMarker(body)
            // 목록 줄만 단계로 다시 맞춘다. 문단의 들여쓰기는 그대로 둔다.
            guard isListLine(marked) else { return String(repeating: " ", count: spaces) + marked }
            let level = unit > 0 ? spaces / unit : 0
            return String(repeating: "  ", count: level) + marked
        }.joined(separator: "\n")
    }

    /// 목록 줄 들여쓰기에서 한 단계가 몇 칸인지 찾는다. 가장 작은 0이 아닌 들여쓰기가 한 단계다.
    private static func indentUnit(of lines: [String]) -> Int {
        var unit = 0
        var insideCode = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(MarkdownParser.codeFence) {
                insideCode.toggle()
                continue
            }
            guard !insideCode else { continue }
            let (spaces, body) = splitIndent(line)
            guard spaces > 0, isListLine(normalizeMarker(body)) else { continue }
            unit = unit == 0 ? spaces : min(unit, spaces)
        }
        return unit
    }

    /// 앞쪽 공백 칸 수와 나머지. 탭 하나는 4칸으로 센다.
    private static func splitIndent(_ line: String) -> (Int, String) {
        var spaces = 0
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == " " { spaces += 1 }
            else if line[index] == "\t" { spaces += 4 }
            else { break }
            index = line.index(after: index)
        }
        return (spaces, String(line[index...]))
    }

    /// 글자로 들어온 목록 · 체크박스 기호를 마크다운 기호로 바꾼다.
    private static let markerReplacements: [(String, String)] = [
        ("☐ ", "- [ ] "), ("☑ ", "- [x] "), ("✅ ", "- [x] "),
        ("[ ] ", "- [ ] "), ("[x] ", "- [x] "), ("[X] ", "- [x] "),
        ("• ", "- "), ("◦ ", "- "), ("▪ ", "- "), ("▫ ", "- "), ("‣ ", "- "), ("⁃ ", "- "),
        ("❝ ", "> "),
    ]

    private static func normalizeMarker(_ body: String) -> String {
        for (from, to) in markerReplacements where body.hasPrefix(from) {
            return to + body.dropFirst(from.count)
        }
        // `* `·`+ ` 글머리와 `* [ ]` 체크박스도 표준 마크다운이다. 파일 해석기는 `- `만 체크박스로 읽는다.
        for star in ["* ", "+ "] where body.hasPrefix(star) {
            return "- " + body.dropFirst(star.count)
        }
        // `1)` 꼴 번호 목록 → `1.`
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(") ") {
            return digits + ". " + body.dropFirst(digits.count + 2)
        }
        return body
    }

    private static func isListLine(_ body: String) -> Bool {
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") { return true }
        // 1. 2. … 번호 목록
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = body.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }
}
