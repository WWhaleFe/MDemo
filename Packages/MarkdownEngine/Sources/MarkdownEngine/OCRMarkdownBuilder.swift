import Foundation

/// 글자 인식이 돌려준 조각 하나. Vision 같은 인식 도구의 타입에 기대지 않는 단순한 값이다.
///
/// 좌표는 이미지 전체를 0~1로 본 정규화 좌표이고, Vision처럼 원점이 왼쪽 아래다
/// (그래서 `y`가 클수록 위쪽이다).
public struct OCRLine: Equatable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double

    public init(text: String, x: Double, y: Double, width: Double, height: Double, confidence: Double = 1) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
    }

    var midY: Double { y + height / 2 }
}

/// 글자 인식 결과를 메모에 넣을 글로 바꾼다 (순수 함수).
///
/// 같은 높이의 조각은 한 줄로 합치고, 줄 간격이 벌어지면 문단을 나눈다.
/// 마크다운 모드에서는 글자 크기로 제목을, 줄머리 기호로 목록·번호·체크를 알아본다.
public enum OCRMarkdownBuilder {
    public enum Mode: Sendable {
        case markdown
        case plain
    }

    /// 제목으로 볼 줄 높이 배율 (본문 중앙값 기준).
    static let heading1Ratio = 1.45
    static let heading2Ratio = 1.2
    /// 이 배율을 넘는 줄 간격은 문단 나눔이다.
    static let paragraphGapRatio = 1.6
    /// 본문 왼쪽 끝에서 줄 높이의 이 배율 이상 안쪽이면 하위 목록이다.
    static let indentRatio = 1.5

    struct Row {
        var fragments: [OCRLine]
        var text: String
        var x: Double
        var midY: Double
        var height: Double
    }

    public static func build(lines: [OCRLine], mode: Mode) -> String {
        MarkdownEngineBackend.current.ocrBuild(lines: lines, mode: mode)
    }

    static func swiftBuild(lines: [OCRLine], mode: Mode) -> String {
        let rows = mergeRows(lines)
        guard !rows.isEmpty else { return "" }

        let bodyHeight = median(rows.map(\.height)) ?? 0
        let spacings = zip(rows, rows.dropFirst()).map { $0.midY - $1.midY }.filter { $0 > 0 }
        let typicalSpacing = median(spacings)
        let minX = rows.map(\.x).min() ?? 0

        var output: [String] = []
        for (index, row) in rows.enumerated() {
            if index > 0, let typicalSpacing, rows[index - 1].midY - row.midY > typicalSpacing * paragraphGapRatio {
                output.append("")
            }
            switch mode {
            case .plain:
                output.append(row.text)
            case .markdown:
                output.append(markdownLine(row, bodyHeight: bodyHeight, minX: minX))
            }
        }
        return output.joined(separator: "\n")
    }

    // MARK: - 줄 합치기

    /// 위에서 아래로, 같은 높이의 조각은 왼쪽부터 한 줄로 묶는다.
    static func mergeRows(_ lines: [OCRLine]) -> [Row] {
        let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let sorted = usable.sorted { $0.midY > $1.midY }

        var groups: [[OCRLine]] = []
        for fragment in sorted {
            if var last = groups.last {
                let averageMid = last.map(\.midY).reduce(0, +) / Double(last.count)
                let rowHeight = max(last.map(\.height).max() ?? 0, fragment.height)
                if abs(fragment.midY - averageMid) <= rowHeight * 0.5 {
                    last.append(fragment)
                    groups[groups.count - 1] = last
                    continue
                }
            }
            groups.append([fragment])
        }

        return groups.map { group in
            let ordered = group.sorted { $0.x < $1.x }
            let text = ordered.map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            return Row(
                fragments: ordered,
                text: text,
                x: ordered.first?.x ?? 0,
                midY: group.map(\.midY).reduce(0, +) / Double(group.count),
                height: group.map(\.height).max() ?? 0
            )
        }
    }

    // MARK: - 마크다운

    private static func markdownLine(_ row: Row, bodyHeight: Double, minX: Double) -> String {
        if bodyHeight > 0 {
            let ratio = row.height / bodyHeight
            if ratio >= heading1Ratio { return "# " + row.text }
            if ratio >= heading2Ratio { return "## " + row.text }
        }
        guard let converted = listLine(row.text) else { return row.text }
        let isNested = row.height > 0 && row.x - minX >= row.height * indentRatio
        return (isNested ? "  " : "") + converted
    }

    private static let uncheckedMarks: Set<Character> = ["☐", "□", "▢"]
    private static let checkedMarks: Set<Character> = ["☑", "✓", "✔", "☒", "■"]
    private static let bulletMarks: Set<Character> = ["•", "·", "▪", "◦"]
    private static let circledNumbers = Array("①②③④⑤⑥⑦⑧⑨⑩")
    private static let numberPattern = try! NSRegularExpression(pattern: #"^(\d{1,3})[.)](?:\s+|$)"#)

    /// 줄머리 기호를 마크다운 목록 표기로 바꾼다. 목록이 아니면 nil.
    static func listLine(_ text: String) -> String? {
        guard let first = text.first else { return nil }
        let rest = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)

        if uncheckedMarks.contains(first) { return "- [ ] " + rest }
        if checkedMarks.contains(first) { return "- [x] " + rest }
        if bulletMarks.contains(first) { return "- " + rest }
        // 영문 하이픈·별표는 "-5도" 같은 글과 헷갈리므로 뒤에 공백이 있을 때만 목록으로 본다.
        if first == "-" || first == "*" {
            guard text.dropFirst().first == " " else { return nil }
            return "- " + rest
        }
        if let index = circledNumbers.firstIndex(of: first) { return "\(index + 1). " + rest }

        let whole = NSRange(location: 0, length: (text as NSString).length)
        if let match = numberPattern.firstMatch(in: text, range: whole) {
            let number = (text as NSString).substring(with: match.range(at: 1))
            let body = (text as NSString).substring(from: match.range.length).trimmingCharacters(in: .whitespaces)
            return "\(number). " + body
        }
        return nil
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
