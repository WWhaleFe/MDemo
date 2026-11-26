import Foundation
import MemoCore

/// 저장되지 않은 설정도 일관된 기본값으로 읽는다.
public struct MemoStripSettings: Equatable, Sendable {
    public var showRelations: Bool
    public var expandedStyle: String
    public var depth: Int
    public init(defaults: UserDefaults = AppSettings.defaults) {
        showRelations = defaults.object(forKey: "memoStrip.showRelations") as? Bool ?? true
        expandedStyle = defaults.string(forKey: "memoStrip.expandedStyle") == "map" ? "map" : "list"
        depth = defaults.integer(forKey: "memoStrip.depth") == 2 ? 2 : 1
    }
}

public struct MemoStripRelations: Equatable, Sendable {
    public struct Direct: Hashable, Sendable {
        public let kind: MemoLinkKind
        public let outgoing: Bool
        public let other: MemoID
    }
    public struct Indirect: Hashable, Sendable {
        public let via: MemoID
        public let kind: MemoLinkKind
        public let outgoing: Bool
        public let other: MemoID
    }
    public let flow: MemoFlow?
    public let direct: [Direct]
    public let indirect: [Indirect]
    public func isVisible(showRelations: Bool) -> Bool { flow != nil || (showRelations && !direct.isEmpty) }

    /// 입력 순서를 보존하고 같은 두 단계 목적지는 처음 발견한 경로로만 보여 준다.
    public static func calculate(current: MemoID, flow: MemoFlow?, edges: [MemoEdge], depth: Int, showRelations: Bool = true) -> Self {
        if let backend = BoardEngineBackend.current {
            let value = backend.relations(current: current, edges: edges, depth: depth, showRelations: showRelations)
            return Self(flow: flow,
                        direct: value.direct.map { Direct(kind: $0.kind, outgoing: $0.outgoing, other: $0.other) },
                        indirect: value.indirect.map { Indirect(via: $0.via, kind: $0.kind, outgoing: $0.outgoing, other: $0.other) })
        }
        let edges = edges.filter { $0.from != $0.to && (showRelations || $0.kind == .flow) }
        func neighbors(_ id: MemoID) -> [Direct] {
            var seen = Set<Direct>()
            return edges.compactMap { edge in
                guard edge.from == id || edge.to == id else { return nil }
                let item = Direct(kind: edge.kind, outgoing: edge.from == id, other: edge.from == id ? edge.to : edge.from)
                return seen.insert(item).inserted ? item : nil
            }
        }
        let direct = neighbors(current)
        var excluded = Set(direct.map(\.other)); excluded.insert(current)
        var indirect: [Indirect] = []
        if depth == 2 {
            for neighbor in direct {
                for item in neighbors(neighbor.other) where excluded.insert(item.other).inserted {
                    indirect.append(Indirect(via: neighbor.other, kind: item.kind, outgoing: item.outgoing, other: item.other))
                    if indirect.count == 12 { break }
                }
                if indirect.count == 12 { break }
            }
        }
        return Self(flow: flow, direct: direct, indirect: indirect)
    }
}
