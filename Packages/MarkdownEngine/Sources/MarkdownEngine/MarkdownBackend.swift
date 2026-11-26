import Foundation

/// 공개 진입점의 교체 뒷단. 화면과 Rust 경계 사이에 패키지 의존성을 만들지 않는다.
public protocol MarkdownBackend: Sendable {
    func imageParse(_ line: String) -> MarkdownImage?
    func imageValidName(_ name: String) -> Bool
    func color(_ hex: String?) -> String?
    func orderedStyle(forIndent indent: Int) -> OrderedListMarker.Style
    func orderedText(number: Int, indent: Int) -> String
    func orderedLetters(_ number: Int) -> String
    func orderedRoman(_ number: Int) -> String
    func imageFileName(_ image: MarkdownImage) -> String
    func imageMarkup(_ image: MarkdownImage) -> String
    func slashStandard() -> [SlashCommand]
    func slashInlineHints() -> [(label: String, shortcut: String)]
    func parse(_ markdown: String) -> [StyledLine]
    func parseLine(_ line: String) -> StyledLine
    func parseInline(_ text: String) -> [StyledSpan]
    func serialize(_ lines: [StyledLine], flavor: MarkdownSerializer.Flavor) -> String
    func serializeLine(_ line: StyledLine, flavor: MarkdownSerializer.Flavor) -> String
    func tableIsRow(_ line: String) -> Bool
    func tableIsSeparatorRow(_ line: String) -> Bool
    func tableCells(of line: String) -> [String]
    func tableColumnCount(of line: String) -> Int
    func tableIsEmptyRow(_ line: String) -> Bool
    func separatorRow(columns: Int) -> String
    func emptyRow(columns: Int) -> String
    func row(cells: [String]) -> String
    func skeleton(columns: Int, rows: Int) -> [String]
    func pastedNormalize(_ text: String) -> String
    func pastedParse(_ text: String) -> [StyledLine]
    func ocrBuild(lines: [OCRLine], mode: OCRMarkdownBuilder.Mode) -> String
    func imageSanitized(_ text: String) -> String
    func imageDefaultName(alt: String, memoTitle: String?, ordinal: Int, fileExtension: String) -> String
    func slashFilter(_ query: String, in commands: [SlashCommand]) -> [SlashCommand]
    func firstMatch(_ context: InputRuleContext, rules: [MarkdownRule]) -> InputRuleMatch?
}

/// 사용자 규칙은 기존 Swift 확장 지점에 남기고 기본 규칙은 순서까지 뒷단에 전달한다.
public enum MarkdownRule: Sendable {
    case codeBlock, heading, checkbox, bullet, ordered
    case paired(delimiter: String, style: InlineStyleTag)
}

/// 시작 시 한 번 설치한다. 설치와 읽기는 같은 잠금으로 보호한다.
public enum MarkdownEngineBackend {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var backend: any MarkdownBackend = SwiftMarkdownBackend()
        var installed = false
    }
    private static let state = State()
    public static var current: any MarkdownBackend {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.backend
    }
    @discardableResult
    public static func install(_ backend: any MarkdownBackend) -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.installed else { return false }
        state.backend = backend
        state.installed = true
        return true
    }
}

public struct SwiftMarkdownBackend: MarkdownBackend {
    public init() {}
    public func imageParse(_ line: String) -> MarkdownImage? { MarkdownImage.swiftParse(line) }
    public func imageValidName(_ name: String) -> Bool { MarkdownImage.swiftIsValidFileName(name) }
    public func color(_ hex: String?) -> String? { InlineColor.swiftNormalized(hex) }
    public func orderedStyle(forIndent indent: Int) -> OrderedListMarker.Style { OrderedListMarker.swiftStyle(forIndent: indent) }
    public func orderedText(number: Int, indent: Int) -> String { OrderedListMarker.swiftText(number: number, indent: indent) }
    public func orderedLetters(_ number: Int) -> String { OrderedListMarker.swiftLetters(number) }
    public func orderedRoman(_ number: Int) -> String { OrderedListMarker.swiftRoman(number) }
    public func imageFileName(_ image: MarkdownImage) -> String { image.swiftFileName }
    public func imageMarkup(_ image: MarkdownImage) -> String { image.swiftMarkdown }
    public func slashStandard() -> [SlashCommand] { SlashCommandCatalog.swiftStandard }
    public func slashInlineHints() -> [(label: String, shortcut: String)] { SlashCommandCatalog.swiftInlineHints }
    public func parse(_ markdown: String) -> [StyledLine] { MarkdownParser.swiftParse(markdown) }
    public func parseLine(_ line: String) -> StyledLine { MarkdownParser.swiftParseLine(line) }
    public func parseInline(_ text: String) -> [StyledSpan] { MarkdownParser.swiftParseInline(text) }
    public func serialize(_ lines: [StyledLine], flavor: MarkdownSerializer.Flavor) -> String { MarkdownSerializer.swiftSerialize(lines, flavor: flavor) }
    public func serializeLine(_ line: StyledLine, flavor: MarkdownSerializer.Flavor) -> String { MarkdownSerializer.swiftSerializeLine(line, flavor: flavor) }
    public func tableIsRow(_ line: String) -> Bool { MarkdownTable.swiftIsRow(line) }
    public func tableIsSeparatorRow(_ line: String) -> Bool { MarkdownTable.swiftIsSeparatorRow(line) }
    public func tableCells(of line: String) -> [String] { MarkdownTable.swiftCells(of: line) }
    public func tableColumnCount(of line: String) -> Int { MarkdownTable.swiftColumnCount(of: line) }
    public func tableIsEmptyRow(_ line: String) -> Bool { MarkdownTable.swiftIsEmptyRow(line) }
    public func separatorRow(columns: Int) -> String { MarkdownTable.swiftSeparatorRow(columns: columns) }
    public func emptyRow(columns: Int) -> String { MarkdownTable.swiftEmptyRow(columns: columns) }
    public func row(cells: [String]) -> String { MarkdownTable.swiftRow(cells: cells) }
    public func skeleton(columns: Int, rows: Int) -> [String] { MarkdownTable.swiftSkeleton(columns: columns, rows: rows) }
    public func pastedNormalize(_ text: String) -> String { PastedMarkdown.swiftNormalize(text) }
    public func pastedParse(_ text: String) -> [StyledLine] { PastedMarkdown.swiftParse(text) }
    public func ocrBuild(lines: [OCRLine], mode: OCRMarkdownBuilder.Mode) -> String { OCRMarkdownBuilder.swiftBuild(lines: lines, mode: mode) }
    public func imageSanitized(_ text: String) -> String { ImageSaveName.swiftSanitized(text) }
    public func imageDefaultName(alt: String, memoTitle: String?, ordinal: Int, fileExtension: String) -> String { ImageSaveName.swiftDefaultName(alt: alt, memoTitle: memoTitle, ordinal: ordinal, fileExtension: fileExtension) }
    public func slashFilter(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] { SlashCommandCatalog.swiftFilter(query, in: commands) }
    public func firstMatch(_ context: InputRuleContext, rules: [MarkdownRule]) -> InputRuleMatch? {
        for rule in rules {
            let match: InputRuleMatch?
            switch rule {
            case .codeBlock: match = CodeBlockRule().swiftMatch(context)
            case .heading: match = HeadingRule().swiftMatch(context)
            case .checkbox: match = CheckboxRule().swiftMatch(context)
            case .bullet: match = BulletListRule().swiftMatch(context)
            case .ordered: match = OrderedListRule().swiftMatch(context)
            case .paired(let delimiter, let style):
                match = PairedDelimiterRule(id: "", delimiter: delimiter, style: style).swiftMatch(context)
            }
            if let match { return match }
        }
        return nil
    }
}
