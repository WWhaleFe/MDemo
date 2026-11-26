import Foundation
import CoreBridge

/// Swift 값과 UniFFI 레코드만 변환한다. 계산 규칙은 Rust 한 곳에서 처리한다.
public struct RustBoardBackend: BoardBackend {
    public init() {}

    /// 저장소 조립과 시험 러너가 공유하는 설치 경로다. 한 프로세스에서 한 번만 교체한다.
    public static func installIfRequested() {
        if CoreStorage.usesRust {
            BoardEngineBackend.install(Self())
        }
    }

    private func records(_ edges: [MemoEdge]) -> [BoardEdgeFfi] {
        edges.map { BoardEdgeFfi(from: $0.from.rawValue, to: $0.to.rawValue, kind: $0.kind.rawValue) }
    }

    public func arrange(ids: [MemoID], edges: [MemoEdge]) -> [(id: MemoID, x: Double, y: Double)] {
        boardArrange(ids: ids.map(\.rawValue), edges: records(edges)).map { (id: MemoID(rawValue: $0.id), x: $0.x, y: $0.y) }
    }

    public func route(edges: [MemoEdge], positions: [MemoID: BoardLayout.Placement], avoiding: [[CGPoint]]) -> [[CGPoint]] {
        let places = positions.map { BoardPlaceFfi(id: $0.key.rawValue, x: $0.value.x, y: $0.value.y) }
        let used = avoiding.map { path in BoardPathFfi(points: path.map { BoardPointFfi(x: $0.x, y: $0.y) }) }
        return boardRoute(edges: records(edges), positions: places, avoiding: used).map { path in
            path.points.map { CGPoint(x: $0.x, y: $0.y) }
        }
    }

    public func crossings(paths: [[CGPoint]]) -> [BoardCrossing] {
        let records = paths.map { path in BoardPathFfi(points: path.map { BoardPointFfi(x: $0.x, y: $0.y) }) }
        return boardCrossings(paths: records).map {
            BoardCrossing(point: CGPoint(x: $0.x, y: $0.y), horizontalPipe: Int($0.horizontalPipe), segment: Int($0.segment))
        }
    }

    public func relations(current: MemoID, edges: [MemoEdge], depth: Int, showRelations: Bool) -> BoardRelations {
        let value = boardRelations(current: current.rawValue, edges: records(edges), depth: UInt32(max(0, depth)), showRelations: showRelations)
        return BoardRelations(
            direct: value.direct.compactMap { item in
                MemoLinkKind(rawValue: item.kind).map { .init(kind: $0, outgoing: item.outgoing, other: MemoID(rawValue: item.other)) }
            },
            indirect: value.indirect.compactMap { item in
                MemoLinkKind(rawValue: item.kind).map { .init(via: MemoID(rawValue: item.via), kind: $0, outgoing: item.outgoing, other: MemoID(rawValue: item.other)) }
            }
        )
    }
}
