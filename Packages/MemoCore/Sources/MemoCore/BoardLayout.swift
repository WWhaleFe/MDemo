import Foundation

/// 기기 간 공유할 보드 위치와 벤토 크기 (설계서 §4).
public struct BoardLayout: Codable, Equatable, Sendable {
    public struct Placement: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// 벤토 칸 크기. small 1x1, wide 2x1, tall 1x2, large 2x2.
    public enum BentoSpan: String, Codable, Sendable, CaseIterable {
        case small, wide, tall, large

        public var columns: Int { self == .wide || self == .large ? 2 : 1 }
        public var rows: Int { self == .tall || self == .large ? 2 : 1 }
    }

    /// JSON 객체 키로 쓰려고 MemoID.rawValue를 키로 둔다.
    public var placements: [String: Placement]
    public var bentoSpans: [String: BentoSpan]

    public init(placements: [String: Placement] = [:], bentoSpans: [String: BentoSpan] = [:]) {
        self.placements = placements
        self.bentoSpans = bentoSpans
    }

    public func placement(for id: MemoID) -> Placement? { placements[id.rawValue] }
    public func bentoSpan(for id: MemoID) -> BentoSpan? { bentoSpans[id.rawValue] }
    public static let empty = BoardLayout()
}
