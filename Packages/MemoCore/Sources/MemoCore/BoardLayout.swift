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

    public var manualOrder: [MemoID]

    public init(placements: [String: Placement] = [:], bentoSpans: [String: BentoSpan] = [:], manualOrder: [MemoID] = []) {
        self.placements = placements
        self.bentoSpans = bentoSpans
        self.manualOrder = manualOrder
    }

    private enum CodingKeys: String, CodingKey { case placements, bentoSpans, manualOrder }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        placements = try values.decodeIfPresent([String: Placement].self, forKey: .placements) ?? [:]
        bentoSpans = try values.decodeIfPresent([String: BentoSpan].self, forKey: .bentoSpans) ?? [:]
        manualOrder = try values.decodeIfPresent([MemoID].self, forKey: .manualOrder) ?? []
    }

    /// 새 메모는 맨 위에 놓고, 없어진 메모와 중복된 ID는 버린다.
    public func normalizedOrder(among ids: [MemoID]) -> [MemoID] {
        let alive = Set(ids)
        var seen = Set<MemoID>()
        let saved = manualOrder.filter { alive.contains($0) && seen.insert($0).inserted }
        return ids.filter { !seen.contains($0) } + saved
    }

    public func placement(for id: MemoID) -> Placement? { placements[id.rawValue] }
    public func bentoSpan(for id: MemoID) -> BentoSpan? { bentoSpans[id.rawValue] }
    public static let empty = BoardLayout()
}
