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

    public var arrangeInOrder: ([MemoID]) -> Void
    /// 그 메모를 띄우고 이미지로 내보내기 시트를 연다.
    public var exportAsImage: (MemoID) -> Void
    /// 창 밖(저장소 경로)에서 그 메모 본문을 고친다. 떠 있는 창이 있으면 고치기 전에 창의 편집 내용을 저장하고,
    /// 고친 뒤 창 내용을 다시 읽는다. 창이 없으면 고치기만 한다.
    public var withExternalBodyEdit: (MemoID, () -> Void) -> Void
    /// 새 메모를 만들어 띄우고 바로 AirDrop 사진 받기를 시작한다.
    public var createLockedMemo: () -> Void
    public var moveToLocked: (MemoID) -> Void
    public var moveToPlain: (MemoID) -> Void
    public var changePassword: (MemoID) -> Void
    public var isUnlocked: (MemoID) -> Bool
    public var createMemoReceivingAirDrop: () -> Void

    public init(
        isVisible: @escaping (MemoID) -> Bool = { _ in false },
        open: @escaping ([MemoID]) -> Void = { _ in },
        hide: @escaping ([MemoID]) -> Void = { _ in },
        arrange: @escaping (_ byGroup: Bool) -> Void = { _ in },
        arrangeInOrder: @escaping ([MemoID]) -> Void = { _ in },
        exportAsImage: @escaping (MemoID) -> Void = { _ in },
        withExternalBodyEdit: @escaping (MemoID, () -> Void) -> Void = { _, edit in edit() },
        createLockedMemo: @escaping () -> Void = {},
        moveToLocked: @escaping (MemoID) -> Void = { _ in },
        moveToPlain: @escaping (MemoID) -> Void = { _ in },
        changePassword: @escaping (MemoID) -> Void = { _ in },
        isUnlocked: @escaping (MemoID) -> Bool = { _ in false },
        createMemoReceivingAirDrop: @escaping () -> Void = {}
    ) {
        self.createLockedMemo = createLockedMemo
        self.moveToLocked = moveToLocked
        self.moveToPlain = moveToPlain
        self.changePassword = changePassword
        self.isUnlocked = isUnlocked
        self.isVisible = isVisible
        self.open = open
        self.hide = hide
        self.arrange = arrange
        self.arrangeInOrder = arrangeInOrder
        self.exportAsImage = exportAsImage
        self.withExternalBodyEdit = withExternalBodyEdit
        self.createMemoReceivingAirDrop = createMemoReceivingAirDrop
    }

    /// 창 계층이 없는 자리에서 쓰는 빈 구현.
    public static let none = MemoWindowActions()
}
