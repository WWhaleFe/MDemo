import MemoCore
import SwiftUI

private struct BentoSpanKey: LayoutValueKey {
    static let defaultValue = BoardLayout.BentoSpan.small
}
extension View {
    func bentoSpan(_ span: BoardLayout.BentoSpan) -> some View { layoutValue(key: BentoSpanKey.self, value: span) }
}

/// 위에서 아래로 빈칸을 찾아 채우는 벤토 배치
struct BentoLayout: Layout {
    struct Cell { let rect: CGRect }
    func cells(width proposedWidth: CGFloat, subviews: Subviews) -> [Cell] {
        // SwiftUI는 최소·최대 크기를 물을 때 0과 무한대도 제안한다.
        let width = proposedWidth.isFinite ? max(0, proposedWidth) : 880
        let columns = Int(max(2, min(4, width / 220)))
        let unit = max(0, (width - CGFloat(columns - 1) * 16) / CGFloat(columns))
        var occupied = Set<Int>()
        var result: [Cell] = []
        for view in subviews {
            let span = view[BentoSpanKey.self]
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
            result.append(Cell(rect: CGRect(x: CGFloat(column) * (unit + 16), y: CGFloat(row) * 148,
                                           width: unit * CGFloat(w) + CGFloat(w - 1) * 16, height: CGFloat(h) * 132 + CGFloat(h - 1) * 16)))
        }
        return result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let suggested = proposal.width ?? 880
        let width = suggested.isFinite ? max(0, suggested) : 880
        return CGSize(width: width, height: cells(width: width, subviews: subviews).map(\.rect.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, cell) in zip(subviews, cells(width: bounds.width, subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + cell.rect.minX, y: bounds.minY + cell.rect.minY), proposal: ProposedViewSize(cell.rect.size))
        }
    }
}
