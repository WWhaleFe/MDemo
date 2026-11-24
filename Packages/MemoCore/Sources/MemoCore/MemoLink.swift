import Foundation

/// 메모 사이 연결 종류 (설계서 §4).
public enum MemoLinkKind: String, Sendable, Codable, CaseIterable {
    case flow, related
}

/// 출발 메모의 프론트매터에 기록할 연결 (DOC-02).
public struct MemoLink: Hashable, Sendable, Codable {
    public var to: MemoID
    public var kind: MemoLinkKind

    public init(to: MemoID, kind: MemoLinkKind) {
        self.to = to
        self.kind = kind
    }
}

/// 화면에 그릴 연결 한 줄. flow는 from → to 방향, related는 방향 없음.
public struct MemoEdge: Hashable, Sendable {
    public let from: MemoID
    public let to: MemoID
    public let kind: MemoLinkKind

    public init(from: MemoID, to: MemoID, kind: MemoLinkKind) {
        self.from = from
        self.to = to
        self.kind = kind
    }
}

/// flow 연결로 이어진 메모 묶음. memoIDs는 흐름 순서. id는 첫 메모의 id.
public struct MemoFlow: Hashable, Sendable, Identifiable {
    public let id: MemoID
    public let memoIDs: [MemoID]

    public init(id: MemoID, memoIDs: [MemoID]) {
        self.id = id
        self.memoIDs = memoIDs
    }
}
