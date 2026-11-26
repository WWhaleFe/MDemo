import Foundation

/// 보드 계산의 교체 뒷단. 기본은 설치하지 않으며(nil) 화면 패키지의 Swift 구현을 그대로 쓴다.
/// Rust 저장소를 켜면 `CoreStorage.make`가 Rust 구현을 설치한다.
public protocol BoardBackend: Sendable {
    /// 보드 재정렬. `edges`는 저장기 순서 그대로이고 결과는 `ids` 입력 순서다.
    func arrange(ids: [MemoID], edges: [MemoEdge]) -> [(id: MemoID, x: Double, y: Double)]
    /// 선 길찾기. 양 끝 자리가 있는 선만 입력 순서로 점열을 돌려준다.
    /// `avoiding`은 끄는 중 다시 찾지 않는 선들의 점열('쓴 길')이다.
    func route(edges: [MemoEdge], positions: [MemoID: BoardLayout.Placement], avoiding: [[CGPoint]]) -> [[CGPoint]]
    /// 선끼리 엇갈리는 점. 가로 선 번호와 구간 번호는 입력 점열 기준이다.
    func crossings(paths: [[CGPoint]]) -> [BoardCrossing]
    /// 메모 관계(바로 · 두 단계). 흐름은 호출한 쪽이 들고 있다.
    func relations(current: MemoID, edges: [MemoEdge], depth: Int, showRelations: Bool) -> BoardRelations
}

public struct BoardCrossing: Equatable, Sendable {
    public var point: CGPoint
    public var horizontalPipe: Int
    public var segment: Int
    public init(point: CGPoint, horizontalPipe: Int, segment: Int) {
        self.point = point
        self.horizontalPipe = horizontalPipe
        self.segment = segment
    }
}

public struct BoardRelations: Equatable, Sendable {
    public struct Direct: Equatable, Sendable {
        public var kind: MemoLinkKind
        public var outgoing: Bool
        public var other: MemoID
        public init(kind: MemoLinkKind, outgoing: Bool, other: MemoID) {
            self.kind = kind
            self.outgoing = outgoing
            self.other = other
        }
    }
    public struct Indirect: Equatable, Sendable {
        public var via: MemoID
        public var kind: MemoLinkKind
        public var outgoing: Bool
        public var other: MemoID
        public init(via: MemoID, kind: MemoLinkKind, outgoing: Bool, other: MemoID) {
            self.via = via
            self.kind = kind
            self.outgoing = outgoing
            self.other = other
        }
    }
    public var direct: [Direct]
    public var indirect: [Indirect]
    public init(direct: [Direct], indirect: [Indirect]) {
        self.direct = direct
        self.indirect = indirect
    }
}

/// 시작 시 한 번 설치한다. 설치와 읽기는 같은 잠금으로 보호한다.
public enum BoardEngineBackend {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var backend: (any BoardBackend)?
        var installed = false
    }
    private static let state = State()
    /// 설치된 뒷단. nil이면 호출한 쪽의 Swift 구현을 쓴다.
    public static var current: (any BoardBackend)? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.backend
    }
    @discardableResult
    public static func install(_ backend: any BoardBackend) -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.installed else { return false }
        state.backend = backend
        state.installed = true
        return true
    }
}
