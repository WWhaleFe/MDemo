import MemoCore

/// 리스트 창이 메모 창에게 부탁하는 일들 (LST-06, LST-09 ~ LST-11).
///
/// 리스트 창은 창을 직접 다루지 않는다. 창을 만들고 옮기는 일은 StickyWindow 계층의 몫이고,
/// 이 계층은 "무엇을 해 달라"만 넘긴다. 그래야 화면 없이도 목록 규칙을 시험할 수 있다.
///
/// 기본값은 아무것도 하지 않는 구현이다. 창 계층 없이 모델만 시험할 때 쓴다.
@MainActor
public struct MemoWindowActions {
    /// 그 메모의 창이 지금 화면에 보이는가 (LST-09).
    public var isVisible: (MemoID) -> Bool
    /// 화면에 띄운다 (LST-10).
    public var open: ([MemoID]) -> Void
    /// 화면에서 내린다. 메모는 지워지지 않는다 (LST-10).
    public var hide: ([MemoID]) -> Void
    /// 떠 있는 창을 격자로 늘어놓는다. `byGroup`이면 그룹마다 줄을 나눈다 (LST-06, LST-11).
    public var arrange: (_ byGroup: Bool) -> Void

    public init(
        isVisible: @escaping (MemoID) -> Bool = { _ in false },
        open: @escaping ([MemoID]) -> Void = { _ in },
        hide: @escaping ([MemoID]) -> Void = { _ in },
        arrange: @escaping (_ byGroup: Bool) -> Void = { _ in }
    ) {
        self.isVisible = isVisible
        self.open = open
        self.hide = hide
        self.arrange = arrange
    }

    /// 창 계층이 없는 자리에서 쓰는 빈 구현.
    public static let none = MemoWindowActions()
}
