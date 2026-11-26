import Foundation
import MarkdownEngine

// 마크다운 엔진 비교 (P5). 사례마다 실제 엔진을 그대로 호출하고, 키를 정렬한 한 줄 JSON으로 적는다.
// Rust의 mdemo-golden/src/markdown_cases.rs가 같은 형식으로 출력해 바이트 단위로 비교한다.
//
// 입력(markdown-cases.json): documents, lines, inlines, tables, pastes, ocr, imageNames, slash, inputRules, images, markers
private indirect enum J {
    case null, bool(Bool), int(Int), str(String), arr([J]), obj([String: J])

    var text: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .str(let value): J.escape(value)
        case .arr(let values): "[" + values.map(\.text).joined(separator: ",") + "]"
        case .obj(let values): "{" + values.keys.sorted().map { J.escape($0) + ":" + values[$0]!.text }.joined(separator: ",") + "}"
        }
    }

    /// 따옴표 · 역슬래시 · 제어 문자(0x20 미만)만 바꾸고 나머지는 그대로 UTF-8로 적는다.
    static func escape(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func optional(_ value: String?) -> J { value.map(J.str) ?? .null }
}

private struct BlockSpec: Decodable {
    var kind: String
    var level: Int?
    var indent: Int?
    var number: Int?
    var checked: Bool?
    var alt: String?
    var path: String?
    var width: Int?

    var style: BlockStyle {
        switch kind {
        case "heading": .heading(level: level ?? 1)
        case "bullet": .bullet(indent: indent ?? 0)
        case "ordered": .ordered(indent: indent ?? 0, number: number ?? 1)
        case "checkbox": .checkbox(indent: indent ?? 0, checked: checked ?? false)
        case "quote": .quote
        case "divider": .divider
        case "codeBlock": .codeBlock
        case "tableRow": .tableRow
        case "image": .image(MarkdownImage(alt: alt ?? "", path: path ?? "", width: width))
        default: .paragraph
        }
    }
}

private struct OCRFragment: Decodable { var text: String; var x: Double; var y: Double; var width: Double; var height: Double }
private struct OCRCase: Decodable { var lines: [OCRFragment] }
private struct ImageNameCase: Decodable { var alt: String; var title: String?; var ordinal: Int; var ext: String }
private struct InputRuleCase: Decodable { var content: String; var caret: Int; var block: BlockSpec }
private struct MarkerCase: Decodable { var number: Int; var indent: Int }
private struct Cases: Decodable {
    var documents: [String] = []
    var lines: [String] = []
    var inlines: [String] = []
    var tables: [String] = []
    var pastes: [String] = []
    var ocr: [OCRCase] = []
    var imageNames: [ImageNameCase] = []
    var slash: [String] = []
    var inputRules: [InputRuleCase] = []
    var images: [String] = []
    var markers: [MarkerCase] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        documents = try c.decodeIfPresent([String].self, forKey: .documents) ?? []
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        inlines = try c.decodeIfPresent([String].self, forKey: .inlines) ?? []
        tables = try c.decodeIfPresent([String].self, forKey: .tables) ?? []
        pastes = try c.decodeIfPresent([String].self, forKey: .pastes) ?? []
        ocr = try c.decodeIfPresent([OCRCase].self, forKey: .ocr) ?? []
        imageNames = try c.decodeIfPresent([ImageNameCase].self, forKey: .imageNames) ?? []
        slash = try c.decodeIfPresent([String].self, forKey: .slash) ?? []
        inputRules = try c.decodeIfPresent([InputRuleCase].self, forKey: .inputRules) ?? []
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        markers = try c.decodeIfPresent([MarkerCase].self, forKey: .markers) ?? []
    }

    enum Key: String, CodingKey { case documents, lines, inlines, tables, pastes, ocr, imageNames, slash, inputRules, images, markers }
}

private func blockJSON(_ block: BlockStyle) -> J {
    switch block {
    case .paragraph: .obj(["kind": .str("paragraph")])
    case .heading(let level): .obj(["kind": .str("heading"), "level": .int(level)])
    case .bullet(let indent): .obj(["kind": .str("bullet"), "indent": .int(indent)])
    case .ordered(let indent, let number): .obj(["kind": .str("ordered"), "indent": .int(indent), "number": .int(number)])
    case .checkbox(let indent, let checked): .obj(["kind": .str("checkbox"), "indent": .int(indent), "checked": .bool(checked)])
    case .quote: .obj(["kind": .str("quote")])
    case .divider: .obj(["kind": .str("divider")])
    case .codeBlock: .obj(["kind": .str("codeBlock")])
    case .tableRow: .obj(["kind": .str("tableRow")])
    case .image(let image): .obj(["kind": .str("image"), "alt": .str(image.alt), "path": .str(image.path), "width": image.width.map(J.int) ?? .null])
    }
}

private func spansJSON(_ spans: [StyledSpan]) -> J {
    .arr(spans.map { span in
        .obj([
            "text": .str(span.text), "styles": .int(span.styles.rawValue),
            "textColor": .optional(span.textColor), "highlightColor": .optional(span.highlightColor),
        ])
    })
}

private func lineJSON(_ line: StyledLine) -> J {
    .obj(["block": blockJSON(line.block), "spans": spansJSON(line.spans)])
}

private func imageJSON(_ image: MarkdownImage?) -> J {
    guard let image else { return .null }
    return .obj([
        "alt": .str(image.alt), "path": .str(image.path), "width": image.width.map(J.int) ?? .null,
        "fileName": .str(image.fileName), "markdown": .str(image.markdown),
    ])
}

func markdownResults(input: URL) throws -> Data {
    let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: input))

    let documents: [J] = cases.documents.map { source in
        let lines = MarkdownParser.parse(source)
        return .obj([
            "lines": .arr(lines.map(lineJSON)),
            "file": .str(MarkdownSerializer.serialize(lines)),
            "clipboard": .str(MarkdownSerializer.serialize(lines, flavor: .clipboard)),
        ])
    }
    let lines: [J] = cases.lines.map { source in
        let line = MarkdownParser.parseLine(source)
        return .obj([
            "line": lineJSON(line),
            "file": .str(MarkdownSerializer.serializeLine(line)),
            "clip": .str(MarkdownSerializer.serializeLine(line, flavor: .clipboard)),
        ])
    }
    let inlines: [J] = cases.inlines.map { spansJSON(MarkdownParser.parseInline($0)) }
    let tables: [J] = cases.tables.map { source in
        .obj([
            "isRow": .bool(MarkdownTable.isRow(source)),
            "isSeparator": .bool(MarkdownTable.isSeparatorRow(source)),
            "isEmptyRow": .bool(MarkdownTable.isEmptyRow(source)),
            "cells": .arr(MarkdownTable.cells(of: source).map(J.str)),
            "columns": .int(MarkdownTable.columnCount(of: source)),
        ])
    }
    let pastes: [J] = cases.pastes.map { source in
        let parsed = PastedMarkdown.parse(source)
        return .obj([
            "normalized": .str(PastedMarkdown.normalize(source)),
            "lines": .arr(parsed.map(lineJSON)),
            "file": .str(MarkdownSerializer.serialize(parsed)),
        ])
    }
    let ocr: [J] = cases.ocr.map { item in
        let fragments = item.lines.map { OCRLine(text: $0.text, x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        return .obj([
            "markdown": .str(OCRMarkdownBuilder.build(lines: fragments, mode: .markdown)),
            "plain": .str(OCRMarkdownBuilder.build(lines: fragments, mode: .plain)),
        ])
    }
    let imageNames: [J] = cases.imageNames.map { item in
        .obj([
            "name": .str(ImageSaveName.defaultName(alt: item.alt, memoTitle: item.title, ordinal: item.ordinal, fileExtension: item.ext)),
            "sanitized": .str(ImageSaveName.sanitized(item.alt)),
        ])
    }
    let slash: [J] = cases.slash.map { .arr(SlashCommandCatalog.filter($0).map { J.str($0.id) }) }
    let inputRules: [J] = cases.inputRules.map { item in
        let context = InputRuleContext(content: item.content, caretOffset: item.caret, block: item.block.style)
        guard let match = InputRuleSet.m1.firstMatch(context) else { return .null }
        let outcome: J
        switch match.outcome {
        case .block(let block): outcome = .obj(["kind": .str("block"), "block": blockJSON(block)])
        case .inline(let styles): outcome = .obj(["kind": .str("inline"), "styles": .int(styles.rawValue)])
        }
        return .obj([
            "range": .arr([.int(match.range.lowerBound), .int(match.range.upperBound)]),
            "replacement": .str(match.replacement), "outcome": outcome,
        ])
    }
    let images: [J] = cases.images.map { source in
        .obj(["image": imageJSON(MarkdownImage.parse(source)), "validName": .bool(MarkdownImage.isValidFileName(source))])
    }
    let markers: [J] = cases.markers.map { item in
        .obj([
            "text": .str(OrderedListMarker.text(number: item.number, indent: item.indent)),
            "letters": .str(OrderedListMarker.letters(item.number)),
            "roman": .str(OrderedListMarker.roman(item.number)),
            "style": .int(OrderedListMarker.style(forIndent: item.indent).rawValue),
        ])
    }

    let result: J = .obj([
        "documents": .arr(documents), "lines": .arr(lines), "inlines": .arr(inlines), "tables": .arr(tables),
        "pastes": .arr(pastes), "ocr": .arr(ocr), "imageNames": .arr(imageNames), "slash": .arr(slash),
        "inputRules": .arr(inputRules), "images": .arr(images), "markers": .arr(markers),
    ])
    return Data((result.text + "\n").utf8)
}
