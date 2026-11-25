import Foundation
import MarkdownEngine

/// 글자 한 구간. 노션 rich_text 항목 하나에 해당한다.
public struct NotionRichText: Sendable, Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public var strikethrough = false
    public var code = false
    /// 노션 색 이름 (`red`, `yellow_background` 등). nil이면 기본.
    public var color: String?
    public var link: String?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, strikethrough: Bool = false,
                code: Bool = false, color: String? = nil, link: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.code = code
        self.color = color
        self.link = link
    }
}

/// 노션 블록의 중간 표현. 마크다운 해석 결과이고, 보낼 때 `json(uploadedImages:)`로 바꾼다.
public struct NotionBlock: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case paragraph
        case heading(Int)
        case bulleted
        case numbered
        case todo(checked: Bool)
        case quote
        case code(language: String)
        case divider
        /// `rows`는 표의 행. 첫 행이 제목 줄이다.
        case table
        case image(path: String, alt: String)
    }

    public var kind: Kind
    public var richText: [NotionRichText]
    public var children: [NotionBlock]
    /// 표일 때만 쓴다: 행 → 칸 → 글자.
    public var rows: [[[NotionRichText]]]

    public init(_ kind: Kind, richText: [NotionRichText] = [], children: [NotionBlock] = [], rows: [[[NotionRichText]]] = []) {
        self.kind = kind
        self.richText = richText
        self.children = children
        self.rows = rows
    }

    /// 하위 블록을 가질 수 있는 종류 (목록만).
    var allowsChildren: Bool {
        switch kind {
        case .bulleted, .numbered, .todo: return true
        default: return false
        }
    }

    /// 이 블록과 하위 블록이 가리키는 이미지 경로.
    public var imagePaths: [String] {
        var result: [String] = []
        if case .image(let path, _) = kind { result.append(path) }
        for child in children { result += child.imagePaths }
        return result
    }
}

/// 마크다운 → 노션 블록 (순수 함수).
public enum NotionBlocks {
    /// 노션 제한: rich_text 한 항목 글자 수, 한 번에 보낼 블록 수, 한 요청 안의 중첩 단계.
    public static let maxTextLength = 2000
    public static let maxBlocksPerRequest = 100
    public static let maxNesting = 2

    public static func from(markdown: String) -> [NotionBlock] {
        var blocks: [NotionBlock] = []
        var codeLanguage: String?
        var codeLines: [String] = []
        var tableRows: [[[NotionRichText]]] = []

        func flushTable() {
            guard !tableRows.isEmpty else { return }
            let width = tableRows.map(\.count).max() ?? 1
            let padded = tableRows.map { $0 + Array(repeating: [], count: width - $0.count) }
            blocks.append(NotionBlock(.table, rows: padded))
            tableRows = []
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(MarkdownParser.codeFence) {
                if let language = codeLanguage {
                    blocks.append(NotionBlock(.code(language: language), richText: split([NotionRichText(codeLines.joined(separator: "\n"))])))
                    codeLanguage = nil
                    codeLines = []
                } else {
                    flushTable()
                    codeLanguage = notionLanguage(String(trimmed.dropFirst(MarkdownParser.codeFence.count)))
                }
                continue
            }
            if codeLanguage != nil { codeLines.append(raw); continue }
            if MarkdownTable.isSeparatorRow(raw) { continue }
            if MarkdownTable.isRow(raw) {
                tableRows.append(MarkdownTable.cells(of: raw).map { richText(from: MarkdownParser.parseInline($0.trimmingCharacters(in: .whitespaces))) })
                continue
            }
            flushTable()

            let line = MarkdownParser.parseLine(raw)
            let text = richText(from: line.spans)
            switch line.block {
            case .paragraph:
                // 빈 줄은 노션이 블록 사이를 띄우므로 만들지 않는다.
                if !line.plainText.trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(NotionBlock(.paragraph, richText: text))
                }
            case .heading(let level):
                blocks.append(NotionBlock(.heading(min(max(level, 1), 3)), richText: text))
            case .bullet(let indent):
                append(NotionBlock(.bulleted, richText: text), depth: indent, to: &blocks)
            case .ordered(let indent, _):
                append(NotionBlock(.numbered, richText: text), depth: indent, to: &blocks)
            case .checkbox(let indent, let checked):
                append(NotionBlock(.todo(checked: checked), richText: text), depth: indent, to: &blocks)
            case .quote:
                // 이어지는 인용 줄은 한 인용으로 묶는다.
                if var last = blocks.last, case .quote = last.kind {
                    last.richText = split(last.richText + [NotionRichText("\n")] + text)
                    blocks[blocks.count - 1] = last
                } else {
                    blocks.append(NotionBlock(.quote, richText: text))
                }
            case .divider:
                blocks.append(NotionBlock(.divider))
            case .codeBlock, .tableRow:
                break
            case .image(let image):
                blocks.append(NotionBlock(.image(path: image.path, alt: image.alt)))
            }
        }
        // 닫히지 않은 코드 울타리와 표도 내용은 남긴다.
        if let language = codeLanguage {
            blocks.append(NotionBlock(.code(language: language), richText: split([NotionRichText(codeLines.joined(separator: "\n"))])))
        }
        flushTable()
        return blocks
    }

    /// 목록 항목을 들여쓰기 단계만큼 앞 항목의 하위로 넣는다. 한 요청 안의 중첩 한도를 넘으면 그 단계에 둔다.
    private static func append(_ block: NotionBlock, depth: Int, to list: inout [NotionBlock], limit: Int = maxNesting) {
        if depth > 0, limit > 0, !list.isEmpty, list[list.count - 1].allowsChildren,
           list[list.count - 1].children.count < maxBlocksPerRequest {
            append(block, depth: depth - 1, to: &list[list.count - 1].children, limit: limit - 1)
        } else {
            list.append(block)
        }
    }

    /// 한 요청에 보낼 수 있는 개수(100)로 나눈다.
    public static func chunks(_ blocks: [NotionBlock], size: Int = maxBlocksPerRequest) -> [[NotionBlock]] {
        guard !blocks.isEmpty else { return [] }
        return stride(from: 0, to: blocks.count, by: size).map { Array(blocks[$0..<min($0 + size, blocks.count)]) }
    }

    // MARK: - 글자

    /// 서식 구간을 노션 글자 구간으로 바꾼다. `[글](주소)`는 링크로, 2000자를 넘는 구간은 나눈다.
    static func richText(from spans: [StyledSpan]) -> [NotionRichText] {
        var result: [NotionRichText] = []
        for span in spans {
            var base = NotionRichText("", bold: span.styles.contains(.bold), italic: span.styles.contains(.italic),
                                      strikethrough: span.styles.contains(.strikethrough), code: span.styles.contains(.code))
            if let color = span.textColor.flatMap({ notionColor(hex: $0, background: false) }) { base.color = color }
            if span.styles.contains(.highlight) {
                base.color = span.highlightColor.flatMap { notionColor(hex: $0, background: true) } ?? "yellow_background"
            }
            if span.styles.contains(.code) {
                var item = base
                item.text = span.text
                result.append(item)
            } else {
                result += linkSegments(span.text).map { segment in
                    var item = base
                    item.text = segment.text
                    item.link = segment.url
                    return item
                }
            }
        }
        return split(result)
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"\[([^\[\]]+)\]\(([^()\s]+)\)"#)

    private static func linkSegments(_ text: String) -> [(text: String, url: String?)] {
        let whole = NSRange(text.startIndex..., in: text)
        var segments: [(String, String?)] = []
        var cursor = text.startIndex
        for match in linkPattern.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text), let label = Range(match.range(at: 1), in: text),
                  let url = Range(match.range(at: 2), in: text), isSafeLink(String(text[url])) else { continue }
            if cursor < range.lowerBound { segments.append((String(text[cursor..<range.lowerBound]), nil)) }
            segments.append((String(text[label]), String(text[url])))
            cursor = range.upperBound
        }
        if cursor < text.endIndex { segments.append((String(text[cursor...]), nil)) }
        return segments
    }

    /// 노션이 받는 주소만 링크로 쓴다. 그 밖의 주소는 글자로 남는다.
    static func isSafeLink(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
    }

    /// 항목 하나가 2000자(UTF-16 기준)를 넘지 않게 나눈다.
    static func split(_ items: [NotionRichText]) -> [NotionRichText] {
        var result: [NotionRichText] = []
        for item in items where !item.text.isEmpty {
            if item.text.utf16.count <= maxTextLength { result.append(item); continue }
            var piece = ""
            var length = 0
            for character in item.text {
                let units = String(character).utf16.count
                if length + units > maxTextLength {
                    var part = item
                    part.text = piece
                    result.append(part)
                    piece = ""
                    length = 0
                }
                piece.append(character)
                length += units
            }
            if !piece.isEmpty {
                var part = item
                part.text = piece
                result.append(part)
            }
        }
        return result
    }

    // MARK: - 색

    /// 노션 색 이름과 비슷한 값. 가장 가까운 색을 고른다.
    private static let palette: [(name: String, red: Double, green: Double, blue: Double)] = [
        ("gray", 155, 154, 151), ("brown", 147, 114, 100), ("orange", 217, 115, 13), ("yellow", 223, 171, 1),
        ("green", 68, 131, 97), ("blue", 51, 126, 169), ("purple", 144, 101, 176), ("pink", 193, 76, 138), ("red", 212, 76, 71),
    ]

    /// "#RRGGBB" → 노션 색 이름. 검정 · 흰색에 가까우면 기본 색(nil)이다. 글자 색에서만 그렇다.
    static func notionColor(hex: String, background: Bool) -> String? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF), green = Double((value >> 8) & 0xFF), blue = Double(value & 0xFF)
        let maxChannel = max(red, green, blue), minChannel = min(red, green, blue)
        if !background, maxChannel < 70 || minChannel > 225 { return nil }
        let chosen: String
        if maxChannel - minChannel < 30 {
            chosen = "gray"
        } else {
            chosen = palette.min { distance($0, red, green, blue) < distance($1, red, green, blue) }!.name
        }
        return background ? chosen + "_background" : chosen
    }

    private static func distance(_ entry: (name: String, red: Double, green: Double, blue: Double), _ red: Double, _ green: Double, _ blue: Double) -> Double {
        pow(entry.red - red, 2) + pow(entry.green - green, 2) + pow(entry.blue - blue, 2)
    }

    // MARK: - 코드 언어

    private static let supportedLanguages: Set<String> = [
        "abap", "arduino", "bash", "basic", "c", "clojure", "coffeescript", "c++", "c#", "css", "dart", "diff", "docker",
        "elixir", "elm", "erlang", "flow", "fortran", "f#", "gherkin", "glsl", "go", "graphql", "groovy", "haskell", "html",
        "java", "javascript", "json", "julia", "kotlin", "latex", "less", "lisp", "livescript", "lua", "makefile", "markdown",
        "markup", "matlab", "mermaid", "nix", "objective-c", "ocaml", "pascal", "perl", "php", "plain text", "powershell",
        "prolog", "protobuf", "python", "r", "reason", "ruby", "rust", "sass", "scala", "scheme", "scss", "shell", "sql",
        "swift", "typescript", "vb.net", "verilog", "vhdl", "visual basic", "webassembly", "xml", "yaml",
    ]

    private static let languageAliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript", "py": "python", "sh": "shell",
        "zsh": "shell", "yml": "yaml", "cpp": "c++", "cc": "c++", "objc": "objective-c", "objectivec": "objective-c",
        "cs": "c#", "csharp": "c#", "fsharp": "f#", "md": "markdown", "kt": "kotlin", "rb": "ruby", "rs": "rust",
        "dockerfile": "docker", "ps1": "powershell", "text": "plain text", "txt": "plain text", "plaintext": "plain text",
        "golang": "go", "tex": "latex",
    ]

    /// 울타리 뒤의 언어 이름 → 노션이 아는 이름. 모르면 "plain text".
    static func notionLanguage(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        if let alias = languageAliases[name] { return alias }
        return supportedLanguages.contains(name) ? name : "plain text"
    }
}

// MARK: - 노션 요청용 JSON

extension NotionBlock {
    /// 노션 API의 블록 JSON. 올린 이미지(경로 → file_upload id)가 없으면 이미지는 "[이미지]" 문단이 된다.
    public func json(uploadedImages: [String: String] = [:]) -> [String: Any] {
        func text(_ items: [NotionRichText]) -> [[String: Any]] { items.map(Self.richTextJSON) }
        func block(_ type: String, _ body: [String: Any]) -> [String: Any] {
            ["object": "block", "type": type, type: body]
        }
        var childJSON: [[String: Any]] { children.map { $0.json(uploadedImages: uploadedImages) } }
        func withChildren(_ body: [String: Any]) -> [String: Any] {
            children.isEmpty ? body : body.merging(["children": childJSON]) { _, new in new }
        }
        switch kind {
        case .paragraph:
            return block("paragraph", ["rich_text": text(richText)])
        case .heading(let level):
            return block("heading_\(level)", ["rich_text": text(richText)])
        case .bulleted:
            return block("bulleted_list_item", withChildren(["rich_text": text(richText)]))
        case .numbered:
            return block("numbered_list_item", withChildren(["rich_text": text(richText)]))
        case .todo(let checked):
            return block("to_do", withChildren(["rich_text": text(richText), "checked": checked]))
        case .quote:
            return block("quote", ["rich_text": text(richText)])
        case .code(let language):
            return block("code", ["rich_text": text(richText), "language": language])
        case .divider:
            return block("divider", [:])
        case .table:
            let width = max(1, rows.map(\.count).max() ?? 1)
            let rowJSON: [[String: Any]] = rows.map { row in
                block("table_row", ["cells": (row + Array(repeating: [], count: width - row.count)).map(text)])
            }
            return block("table", ["table_width": width, "has_column_header": true, "has_row_header": false, "children": rowJSON])
        case .image(let path, _):
            if let id = uploadedImages[path] {
                return block("image", ["type": "file_upload", "file_upload": ["id": id]])
            }
            return block("paragraph", ["rich_text": [Self.richTextJSON(NotionRichText("[이미지]"))]])
        }
    }

    static func richTextJSON(_ item: NotionRichText) -> [String: Any] {
        var content: [String: Any] = ["content": item.text]
        if let link = item.link { content["link"] = ["url": link] }
        return [
            "type": "text",
            "text": content,
            "annotations": [
                "bold": item.bold, "italic": item.italic, "strikethrough": item.strikethrough,
                "underline": false, "code": item.code, "color": item.color ?? "default",
            ] as [String: Any],
        ]
    }
}
