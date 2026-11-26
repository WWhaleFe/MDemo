import Foundation
import CoreBridge
import MarkdownEngine

/// Swift 공개 값과 UniFFI 레코드만 변환한다. 마크다운 문법은 Rust 한 곳에서 처리한다.
public struct RustMarkdownBackend: MarkdownBackend {
    public init() {}

    /// 저장소 조립과 시험 러너가 공유하는 설치 경로다. 한 프로세스에서 한 번만 교체한다.
    public static func installIfRequested() {
        if CoreStorage.usesRust || ProcessInfo.processInfo.arguments.contains("--rust-markdown") {
            MarkdownEngineBackend.install(Self())
        }
    }

    public func parse(_ markdown: String) -> [StyledLine] { markdownParse(text: markdown).map(\.native) }
    public func parseLine(_ line: String) -> StyledLine { markdownParseLine(text: line).native }
    public func parseInline(_ text: String) -> [StyledSpan] { markdownParseInline(text: text).map(\.native) }
    public func serialize(_ lines: [StyledLine], flavor: MarkdownSerializer.Flavor) -> String {
        markdownSerialize(lines: lines.map(\.record), flavor: flavor.record)
    }
    public func serializeLine(_ line: StyledLine, flavor: MarkdownSerializer.Flavor) -> String {
        markdownSerializeLine(line: line.record, flavor: flavor.record)
    }
    public func tableIsRow(_ line: String) -> Bool { markdownTableIsRow(line: line) }
    public func tableIsSeparatorRow(_ line: String) -> Bool { markdownTableIsSeparatorRow(line: line) }
    public func tableCells(of line: String) -> [String] { markdownTableCells(line: line) }
    public func tableColumnCount(of line: String) -> Int { Int(markdownTableColumnCount(line: line)) }
    public func tableIsEmptyRow(_ line: String) -> Bool { markdownTableIsEmptyRow(line: line) }
    public func separatorRow(columns: Int) -> String { markdownSeparatorRow(columns: Int64(columns)) }
    public func emptyRow(columns: Int) -> String { markdownEmptyRow(columns: Int64(columns)) }
    public func row(cells: [String]) -> String { markdownRow(cells: cells) }
    public func skeleton(columns: Int, rows: Int) -> [String] { markdownSkeleton(columns: Int64(columns), rows: Int64(rows)) }
    public func pastedNormalize(_ text: String) -> String { markdownPastedNormalize(text: text) }
    public func pastedParse(_ text: String) -> [StyledLine] { markdownPastedParse(text: text).map(\.native) }
    public func ocrBuild(lines: [OCRLine], mode: OCRMarkdownBuilder.Mode) -> String {
        markdownOcrBuild(lines: lines.map { MdOcrLine(text: $0.text, x: $0.x, y: $0.y, width: $0.width, height: $0.height, confidence: $0.confidence) }, plain: mode == .plain)
    }
    public func imageSanitized(_ text: String) -> String { markdownImageSanitized(text: text) }
    public func imageDefaultName(alt: String, memoTitle: String?, ordinal: Int, fileExtension: String) -> String {
        markdownImageDefaultName(alt: alt, title: memoTitle, ordinal: Int64(ordinal), extension: fileExtension)
    }
    public func slashFilter(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] {
        markdownSlashFilter(query: query, commands: commands.map(\.record)).map(\.native)
    }
    public func slashInlineHints() -> [(label: String, shortcut: String)] { markdownSlashInlineHints().map { (label: $0.label, shortcut: $0.shortcut) } }
    public func slashStandard() -> [SlashCommand] { markdownSlashStandard().map(\.native) }
    public func imageParse(_ line: String) -> MarkdownImage? { markdownImageParse(line: line)?.native }
    public func imageValidName(_ name: String) -> Bool { markdownImageValidName(name: name) }
    public func imageMarkup(_ image: MarkdownImage) -> String { markdownImageMarkup(image: image.record) }
    public func imageFileName(_ image: MarkdownImage) -> String { markdownImageFileName(image: image.record) }
    public func color(_ hex: String?) -> String? { markdownColor(hex: hex) }
    public func orderedStyle(forIndent indent: Int) -> OrderedListMarker.Style {
        switch markdownOrderedStyle(indent: Int64(indent)) {
        case .number: return .number
        case .letter: return .letter
        case .roman: return .roman
        }
    }
    public func orderedText(number: Int, indent: Int) -> String { markdownOrderedText(number: Int64(number), indent: Int64(indent)) }
    public func orderedLetters(_ number: Int) -> String { markdownOrderedLetters(number: Int64(number)) }
    public func orderedRoman(_ number: Int) -> String { markdownOrderedRoman(number: Int64(number)) }

    /// InputRuleContext와 결과 range는 이미 Character 단위다. 여기서 UTF-16으로 바꾸면 이중 변환이다.
    public func firstMatch(_ context: InputRuleContext, rules: [MarkdownRule]) -> InputRuleMatch? {
        guard let result = markdownFirstMatch(content: context.content, caret: Int64(context.caretOffset), block: context.block.record, rules: rules.map(\.record)) else { return nil }
        let outcome: InputRuleOutcome
        switch result.outcome {
        case .block(let block): outcome = .block(block.native)
        case .inline(let styles): outcome = .inline(InlineStyleTag(rawValue: Int(truncatingIfNeeded: styles)))
        }
        return InputRuleMatch(range: Int(result.start)..<Int(result.end), replacement: result.replacement, outcome: outcome)
    }
}

private extension MarkdownSerializer.Flavor {
    var record: MdFlavor { self == .file ? .file : .clipboard }
}
private extension MarkdownRule {
    var record: MdRule {
        switch self {
        case .codeBlock: return .codeBlock
        case .heading: return .heading
        case .checkbox: return .checkbox
        case .bullet: return .bullet
        case .ordered: return .ordered
        case .paired(let delimiter, let style): return .paired(delimiter: delimiter, styles: UInt64(bitPattern: Int64(style.rawValue)))
        }
    }
}
private extension MarkdownImage {
    var record: MdMarkdownImage { MdMarkdownImage(alt: alt, path: path, width: width.map(Int64.init)) }
}
private extension MdMarkdownImage {
    var native: MarkdownImage {
        // 값 타입의 생성자는 정규화하므로 공개 가변 필드의 현재 값을 그대로 복원한다.
        var result = MarkdownImage(path: path)
        result.alt = alt
        result.width = width.map(Int.init)
        return result
    }
}
private extension BlockStyle {
    var record: MdBlock {
        switch self {
        case .paragraph: return .paragraph
        case .heading(let level): return .heading(level: Int64(level))
        case .bullet(let indent): return .bullet(indent: Int64(indent))
        case .ordered(let indent, let number): return .ordered(indent: Int64(indent), number: Int64(number))
        case .checkbox(let indent, let checked): return .checkbox(indent: Int64(indent), checked: checked)
        case .quote: return .quote
        case .divider: return .divider
        case .codeBlock: return .codeBlock
        case .tableRow: return .tableRow
        case .image(let image): return .image(image: image.record)
        }
    }
}
private extension MdBlock {
    var native: BlockStyle {
        switch self {
        case .paragraph: return .paragraph
        case .heading(let level): return .heading(level: Int(level))
        case .bullet(let indent): return .bullet(indent: Int(indent))
        case .ordered(let indent, let number): return .ordered(indent: Int(indent), number: Int(number))
        case .checkbox(let indent, let checked): return .checkbox(indent: Int(indent), checked: checked)
        case .quote: return .quote
        case .divider: return .divider
        case .codeBlock: return .codeBlock
        case .tableRow: return .tableRow
        case .image(let image): return .image(image.native)
        }
    }
}
private extension StyledSpan {
    var record: MdStyledSpan { MdStyledSpan(text: text, styles: UInt64(bitPattern: Int64(styles.rawValue)), textColor: textColor, highlightColor: highlightColor) }
}
private extension MdStyledSpan {
    var native: StyledSpan {
        var result = StyledSpan(text: text)
        result.styles = InlineStyleTag(rawValue: Int(truncatingIfNeeded: styles))
        result.textColor = textColor
        result.highlightColor = highlightColor
        return result
    }
}
private extension StyledLine {
    var record: MdStyledLine { MdStyledLine(block: block.record, spans: spans.map(\.record)) }
}
private extension MdStyledLine {
    var native: StyledLine { StyledLine(block: block.native, spans: spans.map(\.native)) }
}
private extension SlashCommand {
    var record: MdSlashCommand { MdSlashCommand(id: id, title: title, subtitle: subtitle, keywords: keywords, shortcut: shortcut, block: block.record) }
}
private extension MdSlashCommand {
    var native: SlashCommand { SlashCommand(id: id, title: title, subtitle: subtitle, keywords: keywords, shortcut: shortcut, block: block.native) }
}
