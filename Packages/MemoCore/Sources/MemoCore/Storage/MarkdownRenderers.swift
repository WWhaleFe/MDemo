import Foundation

/// 내보내기용 변환기 (DAT-06).
///
/// 화면에 그리는 일과는 목적이 다르다. 여기서는 다른 프로그램이 읽을 수 있는 형태로 옮긴다.
/// 마크다운 해석은 MarkdownEngine이 더 정확하지만, 이 계층은 UI 없이도 돌아야 해서
/// 내보내기에 필요한 만큼만 여기에 둔다.

public enum MarkdownPlainTextRenderer {
    /// 기호를 걷어내 사람이 읽기 좋은 글로 만든다.
    public static func render(_ markdown: String) -> String {
        markdown
            .components(separatedBy: "\n")
            .map(renderLine)
            .joined(separator: "\n")
    }

    private static func renderLine(_ line: String) -> String {
        var text = line

        // 줄 앞머리 기호
        text = text.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "^(\\s*)- \\[ \\] ", with: "$1☐ ", options: .regularExpression)
        text = text.replacingOccurrences(of: "^(\\s*)- \\[[xX]\\] ", with: "$1☑ ", options: .regularExpression)
        text = text.replacingOccurrences(of: "^(\\s*)[-*] ", with: "$1• ", options: .regularExpression)
        text = text.replacingOccurrences(of: "^> ", with: "", options: .regularExpression)

        // 감싸는 기호
        for marker in ["\\*\\*", "~~", "==", "\\*", "`"] {
            text = text.replacingOccurrences(
                of: "\(marker)(.+?)\(marker)",
                with: "$1",
                options: .regularExpression
            )
        }
        return text
    }
}

public enum MarkdownHTMLRenderer {
    /// 브라우저에서 열 수 있는 HTML로 만든다. 스타일을 안에 넣어 파일 하나로 끝낸다.
    public static func render(_ markdown: String, title: String) -> String {
        let body = markdown
            .components(separatedBy: "\n")
            .map(renderLine)
            .joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="ko">
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        <style>
        body { font-family: -apple-system, "Apple SD Gothic Neo", sans-serif;
               line-height: 1.7; max-width: 42rem; margin: 3rem auto; padding: 0 1.5rem; color: #222; }
        h1, h2, h3 { line-height: 1.3; }
        mark { background: #fff3a3; }
        code { background: #f2f2f2; padding: 0.1em 0.3em; border-radius: 3px; }
        ul { padding-left: 1.2rem; }
        .task { list-style: none; margin-left: -1.2rem; }
        blockquote { border-left: 3px solid #ddd; margin-left: 0; padding-left: 1rem; color: #666; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func renderLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "<br>" }

        if trimmed == "---" { return "<hr>" }

        // 제목
        var level = 0
        var rest = Substring(trimmed)
        while rest.first == "#", level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        if level > 0, rest.first == " " {
            let content = inline(String(rest.dropFirst()))
            return "<h\(level)>\(content)</h\(level)>"
        }

        if trimmed.hasPrefix("- [ ] ") {
            return "<ul><li class=\"task\">☐ \(inline(String(trimmed.dropFirst(6))))</li></ul>"
        }
        if trimmed.lowercased().hasPrefix("- [x] ") {
            return "<ul><li class=\"task\">☑ <s>\(inline(String(trimmed.dropFirst(6))))</s></li></ul>"
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return "<ul><li>\(inline(String(trimmed.dropFirst(2))))</li></ul>"
        }
        if trimmed.hasPrefix("> ") {
            return "<blockquote>\(inline(String(trimmed.dropFirst(2))))</blockquote>"
        }
        if let match = trimmed.range(of: "^\\d+\\. ", options: .regularExpression) {
            return "<ol><li>\(inline(String(trimmed[match.upperBound...])))</li></ol>"
        }
        return "<p>\(inline(trimmed))</p>"
    }

    /// 글자 서식. 코드부터 처리해 그 안의 기호가 서식으로 해석되지 않게 한다.
    private static func inline(_ text: String) -> String {
        var result = escape(text)
        let rules: [(String, String)] = [
            ("`(.+?)`", "<code>$1</code>"),
            ("\\*\\*(.+?)\\*\\*", "<strong>$1</strong>"),
            ("~~(.+?)~~", "<s>$1</s>"),
            ("==(.+?)==", "<mark>$1</mark>"),
            ("\\*(.+?)\\*", "<em>$1</em>"),
        ]
        for (pattern, replacement) in rules {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
