import Foundation

/// 표 (MD-14).
///
/// 표는 여러 줄이 모여 하나가 된다. 이 앱은 줄 단위로 서식을 다루므로,
/// 표의 각 줄에 `BlockStyle.tableRow`를 달고 줄 사이의 관계는 이 도우미가 계산한다.
///
/// **구분 줄(`| --- | --- |`)은 화면에 두지 않는다.** 사람이 읽을 내용이 아니라 문법이기 때문이다.
/// 마크다운 기호를 숨긴다는 원칙(MD-01)과 같은 이유이며, 저장할 때 첫 줄 뒤에 다시 만들어 넣는다.
public enum MarkdownTable {
    public static let pipe: Character = "|"

    /// 표의 한 줄인가. 세로줄로 시작하는 줄만 표로 본다.
    ///
    /// 본문 가운데 있는 `|`까지 표로 보면, 그냥 세로줄을 쓴 문장이 표가 되어 버린다.
    public static func isRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(String(pipe)) && trimmed.count > 1
    }

    /// `| --- | --- |` 처럼 칸이 모두 줄표인 줄인가.
    public static func isSeparatorRow(_ line: String) -> Bool {
        guard isRow(line) else { return false }
        let cells = self.cells(of: line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let body = cell.trimmingCharacters(in: .whitespaces)
            guard body.count >= 3 else { return false }
            // 정렬 표시(`:---`, `---:`, `:---:`)도 구분 줄이다.
            let core = body.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    /// 줄을 칸 단위로 쪼갠다. 양 끝의 빈 칸(세로줄 바깥)은 버린다.
    public static func cells(of line: String) -> [String] {
        var parts = line.trimmingCharacters(in: .whitespaces).split(
            separator: pipe,
            omittingEmptySubsequences: false
        ).map(String.init)
        if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeFirst() }
        if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeLast() }
        return parts
    }

    public static func columnCount(of line: String) -> Int {
        max(1, cells(of: line).count)
    }

    /// 저장할 때 첫 줄 뒤에 넣는 구분 줄.
    public static func separatorRow(columns: Int) -> String {
        row(cells: Array(repeating: "---", count: max(1, columns)))
    }

    /// 빈 줄. 새 행을 만들 때 쓴다.
    public static func emptyRow(columns: Int) -> String {
        row(cells: Array(repeating: "", count: max(1, columns)))
    }

    public static func row(cells: [String]) -> String {
        "\(pipe) " + cells.joined(separator: " \(pipe) ") + " \(pipe)"
    }

    /// 표를 처음 넣을 때의 뼈대. 화면에 그대로 들어가는 줄들이다(구분 줄 제외).
    ///
    /// 첫 줄은 제목 줄이다. 무엇을 채워야 하는지 보이도록 이름을 미리 넣어 둔다 —
    /// 빈 칸만 늘어놓으면 어디가 제목인지 알 수 없다.
    public static func skeleton(columns: Int = 2, rows: Int = 3) -> [String] {
        let headers = (1...max(1, columns)).map { columns == 2 && $0 == 1 ? "항목" : ($0 == 2 ? "내용" : "제목 \($0)") }
        var lines = [row(cells: headers)]
        for _ in 1..<max(2, rows) {
            lines.append(emptyRow(columns: columns))
        }
        return lines
    }

    /// 칸이 비어 있는 줄인가. 빈 줄에서 엔터를 치면 표를 빠져나온다.
    public static func isEmptyRow(_ line: String) -> Bool {
        guard isRow(line) else { return false }
        return cells(of: line).allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
