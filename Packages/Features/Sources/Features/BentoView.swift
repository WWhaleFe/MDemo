import MemoCore
import SwiftUI

/// 벤토 배치 계산. 화면과 무관한 순수 함수로 두어 테스트할 수 있다.
enum BentoGrid {
    static let gap: CGFloat = 16
    static let rowHeight: CGFloat = 132
    static let pitch: CGFloat = 148

    /// 위에서 아래로 빈칸을 찾아 채운 칸 위치와 열 수
    static func bentoCells(spans: [BoardLayout.BentoSpan], width proposedWidth: CGFloat) -> (cells: [CGRect], columns: Int) {
        let width = proposedWidth.isFinite ? max(0, proposedWidth) : 880
        let columns = Int(max(2, min(4, width / 220)))
        let unit = max(0, (width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        var occupied = Set<Int>()
        var result: [CGRect] = []
        for span in spans {
            let w = min(columns, span.columns)
            let h = span.rows
            var row = 0
            var column = 0
            search: while true {
                for x in 0...(columns - w) {
                    let slots = (0..<h).flatMap { y in (0..<w).map { (row + y) * columns + x + $0 } }
                    if slots.allSatisfy({ !occupied.contains($0) }) {
                        column = x
                        occupied.formUnion(slots)
                        break search
                    }
                }
                row += 1
            }
            result.append(CGRect(x: CGFloat(column) * (unit + gap), y: CGFloat(row) * pitch,
                                 width: unit * CGFloat(w) + CGFloat(w - 1) * gap, height: CGFloat(h) * rowHeight + CGFloat(h - 1) * gap))
        }
        return (result, columns)
    }

    struct Band: Equatable {
        var rowRange: Range<Int>
        var cardIndices: [Int]
        var height: CGFloat
        var minY: CGFloat { CGFloat(rowRange.lowerBound) * pitch }
    }

    /// 어떤 카드도 가로지르지 않는 행 경계에서 잘라 띠로 나눈다. 띠 하나는 보통 rowsPerBand행 안팎이다.
    static func bands(cells: [CGRect], rowsPerBand: Int = 3) -> [Band] {
        guard !cells.isEmpty else { return [] }
        let starts = cells.map { Int(($0.minY / pitch).rounded()) }
        let ends = zip(cells, starts).map { cell, start in start + Int(((cell.height + gap) / pitch).rounded()) }
        let rowCount = ends.max() ?? 0
        // crossed[r]: r행과 r+1행 사이를 가로지르는 카드가 있는지
        var crossed = [Bool](repeating: false, count: rowCount + 1)
        for (start, end) in zip(starts, ends) where end - start > 1 {
            for r in start..<(end - 1) { crossed[r] = true }
        }
        var bands: [Band] = []
        var first = 0
        while first < rowCount {
            var last = min(rowCount, first + max(1, rowsPerBand)) - 1
            while last < rowCount - 1 && crossed[last] { last += 1 }
            let range = first..<(last + 1)
            let indices = starts.indices.filter { range.contains(starts[$0]) }
            bands.append(Band(rowRange: range, cardIndices: indices, height: CGFloat(range.count) * pitch - gap))
            first = last + 1
        }
        return bands
    }
}
