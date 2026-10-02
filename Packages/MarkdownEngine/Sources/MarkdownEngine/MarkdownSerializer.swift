import Foundation

/// 서식이 적용된 문서를 표준 마크다운 문자열로 되돌린다 (DOC-01, CHK-05).
///
/// 화면에서는 기호를 숨기지만 파일에는 반드시 기호가 살아 있어야 한다.
/// 다른 마크다운 도구로 열었을 때 그대로 읽히는 것이 이 앱의 저장 원칙이다.
public enum MarkdownSerializer {
    /// 어디에 쓸 마크다운인가.
    public enum Flavor: Sendable {
        /// 메모 파일. 이 앱의 확장(==형광==, 색 태그)을 모두 남긴다.
        case file
        /// 클립보드 — 노션 등 다른 앱에 붙여 넣을 글.
        /// 노션은 붙여 넣은 마크다운을 블록으로 바꿔 주지만 색 태그와 ==형광==은 모른다.
        /// 그대로 보내면 기호가 글자로 박히므로, 기호를 빼고 글자만 남긴다.
        /// 목록 들여쓰기는 4칸으로 한다 — 표준 마크다운에서 번호 목록 아래 단계는 3칸 이상이어야 인식된다.
        case clipboard

        var indentUnit: String { self == .file ? "  " : "    " }
        var keepsAppExtensions: Bool { self == .file }
    }

    public static func serialize(_ lines: [StyledLine], flavor: Flavor = .file) -> String {
        var out: [String] = []
        var insideCodeBlock = false
        var insideTable = false

        for line in lines {
            let isCode = line.block == .codeBlock
            // 코드 박스는 줄마다 기호를 붙이는 대신, 시작과 끝에 울타리를 한 번씩 친다 (MD-10).
            if isCode != insideCodeBlock {
                out.append(MarkdownParser.codeFence)
                insideCodeBlock = isCode
            }

            let text = serializeLine(line, flavor: flavor)
            out.append(text)

            // 표는 첫 줄 뒤에 구분 줄이 있어야 표로 읽힌다. 화면에 없던 것을 여기서 되살린다 (MD-14).
            let isTable = line.block == .tableRow
            if isTable, !insideTable {
                out.append(MarkdownTable.separatorRow(columns: MarkdownTable.columnCount(of: text)))
            }
            insideTable = isTable
        }
        if insideCodeBlock {
            out.append(MarkdownParser.codeFence)
        }
        return out.joined(separator: "\n")
    }

    public static func serializeLine(_ line: StyledLine, flavor: Flavor = .file) -> String {
        // 코드는 있는 그대로 적는다. 기호를 붙이면 코드가 아니게 된다.
        if line.block == .codeBlock {
            return line.spans.map(\.text).joined()
        }
        let content = line.spans.map { serializeSpan($0, flavor: flavor) }.joined()
        return blockPrefix(for: line.block, flavor: flavor) + content
    }

    private static func blockPrefix(for block: BlockStyle, flavor: Flavor) -> String {
        switch block {
        case .paragraph:
            return ""
        case .heading(let level):
            return String(repeating: "#", count: max(1, min(level, 6))) + " "
        case .bullet(let indent):
            return indentation(indent, flavor) + "- "
        case .ordered(let indent, let number):
            return indentation(indent, flavor) + "\(number). "
        case .checkbox(let indent, let checked):
            return indentation(indent, flavor) + (checked ? "- [x] " : "- [ ] ")
        case .quote:
            return "> "
        case .divider:
            return "---"
        case .codeBlock:
            // 울타리는 serialize가 붙인다. 줄 자체에는 앞머리가 없다.
            return ""
        case .tableRow:
            // 세로줄은 내용에 이미 들어 있다.
            return ""
        }
    }

    /// 들여쓰기 한 단계는 공백 2칸. 탭을 쓰지 않는 이유는 다른 도구에서 폭이 달라 보이기 때문이다.
    private static func indentation(_ level: Int, _ flavor: Flavor) -> String {
        String(repeating: flavor.indentUnit, count: max(0, level))
    }

    /// 겹친 서식은 항상 같은 순서로 감싼다. 순서가 흔들리면 저장할 때마다 파일이 달라져
    /// 동기화가 불필요한 충돌을 만든다 (SYNC-06).
    private static func serializeSpan(_ span: StyledSpan, flavor: Flavor) -> String {
        var text = span.text
        guard !text.isEmpty else { return text }

        // 코드가 가장 안쪽 — 마크다운에서 코드 구간 안의 기호는 서식으로 해석되지 않는다.
        if span.styles.contains(.code) { text = "`\(text)`" }
        if span.styles.contains(.highlight) && flavor.keepsAppExtensions {
            // 기본 노랑은 예전처럼 `==`로 둔다. 이미 저장된 파일이 바뀌지 않게 하기 위해서다.
            if let hex = span.highlightColor {
                text = InlineColor.highlightOpening(hex) + text + InlineColor.highlightClosing
            } else {
                text = "==\(text)=="
            }
        }
        if span.styles.contains(.strikethrough) { text = "~~\(text)~~" }
        if span.styles.contains(.italic) { text = "*\(text)*" }
        if span.styles.contains(.bold) { text = "**\(text)**" }
        // 글자 색이 가장 바깥이다.
        if let hex = span.textColor, flavor.keepsAppExtensions {
            text = InlineColor.textOpening(hex) + text + InlineColor.textClosing
        }
        return text
    }
}
