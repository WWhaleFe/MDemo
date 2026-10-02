import Foundation
import Observation

/// 서식 막대를 붙일 자리 (FMT-02, SET-08).
///
/// 참고한 메모앱들은 대개 아래쪽에 둔다. 다만 스티키 노트는 위에서 아래로 자라므로
/// 커서가 첫 줄에 있는 시간이 길다 — 그래서 기본값은 위쪽으로 두고, 취향에 맞게 옮길 수 있게 했다.
public enum FormatToolbarPosition: String, CaseIterable, Sendable {
    case top
    case bottom
    case left
    case right
    case hidden

    public var label: String {
        switch self {
        case .top: return "위쪽"
        case .bottom: return "아래쪽"
        case .left: return "왼쪽"
        case .right: return "오른쪽"
        case .hidden: return "숨김"
        }
    }

    /// 좌우에 붙는 자리인가. 이때 버튼은 두 줄이 아니라 두 칸으로 선다.
    public var isVertical: Bool {
        self == .left || self == .right
    }
}

/// 전역 환경설정 (SET-01, SET-02).
///
/// 메모마다 다른 값(색상·투명도)은 프론트매터에 들어가고, 여기 있는 값은 앱 전체에 적용된다.
/// 기기마다 화면과 취향이 다르므로 UserDefaults에 두고 동기화하지 않는다.
@MainActor
@Observable
public final class AppPreferences {
    /// 본문 글꼴 가족 이름. nil이면 설치된 글꼴 중에서 자동으로 고른다 (TXT-02).
    public var fontFamily: String? {
        didSet { store.set(fontFamily, forKey: Key.fontFamily) }
    }

    /// 본문 기본 글자 크기 (TXT-03).
    public var fontSize: Double {
        didSet { store.set(fontSize, forKey: Key.fontSize) }
    }

    /// 새 메모를 만들 때의 창 크기 (SET-01).
    public var defaultMemoWidth: Double {
        didSet { store.set(defaultMemoWidth, forKey: Key.defaultMemoWidth) }
    }

    public var defaultMemoHeight: Double {
        didSet { store.set(defaultMemoHeight, forKey: Key.defaultMemoHeight) }
    }

    /// 새 메모를 마지막으로 끌어 맞춘 크기로 열지 (SET-01).
    /// 끄면 위의 기본 크기(메뉴에서 고른 크기)로만 연다.
    public var rememberLastMemoSize: Bool {
        didSet { store.set(rememberLastMemoSize, forKey: Key.rememberLastMemoSize) }
    }

    /// 사용자가 마지막으로 끌어 맞춘 메모 크기. 아직 맞춘 적이 없으면 nil.
    /// 기본 크기와 따로 둔다 — 끌 때마다 기본값을 덮어쓰면 기능을 꺼도 고른 크기로 돌아갈 수 없다.
    public private(set) var lastMemoSize: (width: Double, height: Double)? {
        didSet {
            store.set(lastMemoSize?.width, forKey: Key.lastMemoWidth)
            store.set(lastMemoSize?.height, forKey: Key.lastMemoHeight)
        }
    }

    /// 새 메모를 열 크기. 기능이 켜져 있고 맞춘 크기가 있으면 그것, 아니면 기본 크기.
    public var newMemoSize: (width: Double, height: Double) {
        if rememberLastMemoSize, let lastMemoSize {
            return lastMemoSize
        }
        return (defaultMemoWidth, defaultMemoHeight)
    }

    /// 사용자가 창을 끌어 크기를 바꿨을 때 기록한다. 기본 크기는 건드리지 않는다.
    public func recordResizedMemoSize(width: Double, height: Double) {
        lastMemoSize = (
            max(width, Self.minimumMemoSize.width),
            max(height, Self.minimumMemoSize.height)
        )
    }

    /// iCloud 자동 동기화를 켤지 (SYNC-04, SYNC-05).
    public var autoSyncEnabled: Bool {
        didSet { store.set(autoSyncEnabled, forKey: Key.autoSyncEnabled) }
    }

    /// 자동 동기화 주기(분). 너무 짧으면 파일을 계속 뒤지게 된다.
    public var autoSyncMinutes: Double {
        didSet { store.set(autoSyncMinutes, forKey: Key.autoSyncMinutes) }
    }

    /// 마우스를 올렸을 때 잠깐 또렷하게 할지 (OPA-04, SET-03).
    public var hoverOpaque: Bool {
        didSet { store.set(hoverOpaque, forKey: Key.hoverOpaque) }
    }

    /// 휴지통에 들어간 지 보관 기간이 지난 메모를 저절로 지울지 (TRS-03).
    /// 끄면 사용자가 직접 비울 때까지 휴지통에 남는다.
    public var autoEmptyTrash: Bool {
        didSet { store.set(autoEmptyTrash, forKey: Key.autoEmptyTrash) }
    }

    /// 휴지통 보관 기간(일).
    public static let trashRetentionDays = 30

    /// 서식 막대를 메모 창의 어디에 붙일지 (FMT-02, SET-08).
    public var formatToolbarPosition: FormatToolbarPosition {
        didSet { store.set(formatToolbarPosition.rawValue, forKey: Key.formatToolbarPosition) }
    }

    public static let defaultFontSize: Double = 18
    public static let defaultMemoSize = (width: 420.0, height: 480.0)
    /// 창이 너무 작아 내용을 볼 수 없게 되는 것을 막는다.
    public static let minimumMemoSize = (width: 180.0, height: 120.0)

    /// 사용자가 직접 고른 값인가. 자동 설정은 한 번도 고르지 않았을 때만 적용한다.
    @ObservationIgnored public private(set) var hasChosenFontSize: Bool
    @ObservationIgnored public private(set) var hasChosenMemoSize: Bool

    @ObservationIgnored private let store: UserDefaults

    private enum Key {
        static let fontFamily = "editor.fontFamily"
        static let fontSize = "editor.fontSize"
        static let defaultMemoWidth = "memo.defaultWidth"
        static let defaultMemoHeight = "memo.defaultHeight"
        static let hoverOpaque = "memo.hoverOpaque"
        static let autoSyncEnabled = "sync.autoEnabled"
        static let autoSyncMinutes = "sync.autoMinutes"
        static let formatToolbarPosition = "memo.formatToolbarPosition"
        static let autoEmptyTrash = "trash.autoEmpty"
        static let rememberLastMemoSize = "memo.rememberLastSize"
        static let lastMemoWidth = "memo.lastWidth"
        static let lastMemoHeight = "memo.lastHeight"
    }

    public init(store: UserDefaults = .standard) {
        self.store = store
        self.fontFamily = store.string(forKey: Key.fontFamily)

        // 동기화는 사용자가 켜야 시작한다. 모르는 사이에 파일이 오가면 곤란하다.
        self.autoSyncEnabled = store.object(forKey: Key.autoSyncEnabled) as? Bool ?? false
        let savedMinutes = store.double(forKey: Key.autoSyncMinutes)
        self.autoSyncMinutes = savedMinutes > 0 ? savedMinutes : 5

        // 저장된 값이 없으면 켜 둔다. 투명하게 써 놓고 읽을 때만 또렷해지는 편이 편하다.
        self.hoverOpaque = store.object(forKey: Key.hoverOpaque) as? Bool ?? true

        // 저장된 값이 없으면 켜 둔다. 예전부터 30일이 지나면 비우던 동작 그대로다.
        self.autoEmptyTrash = store.object(forKey: Key.autoEmptyTrash) as? Bool ?? true

        // 서식 막대는 위쪽이 기본이다. 글을 쓰는 자리(첫 줄) 바로 위에 있어야 눈이 덜 움직인다.
        self.formatToolbarPosition = FormatToolbarPosition(
            rawValue: store.string(forKey: Key.formatToolbarPosition) ?? ""
        ) ?? .top
        self.hasChosenFontSize = store.object(forKey: Key.fontSize) != nil
        self.hasChosenMemoSize = store.object(forKey: Key.defaultMemoWidth) != nil

        let savedSize = store.double(forKey: Key.fontSize)
        self.fontSize = savedSize > 0 ? savedSize : Self.defaultFontSize

        let savedWidth = store.double(forKey: Key.defaultMemoWidth)
        self.defaultMemoWidth = savedWidth > 0 ? savedWidth : Self.defaultMemoSize.width

        let savedHeight = store.double(forKey: Key.defaultMemoHeight)
        self.defaultMemoHeight = savedHeight > 0 ? savedHeight : Self.defaultMemoSize.height

        // 저장된 값이 없으면 켜 둔다. 창을 맞춰 쓰는 사람에게 다음 메모도 같은 크기인 편이 자연스럽다.
        self.rememberLastMemoSize = store.object(forKey: Key.rememberLastMemoSize) as? Bool ?? true
        let lastWidth = store.double(forKey: Key.lastMemoWidth)
        let lastHeight = store.double(forKey: Key.lastMemoHeight)
        self.lastMemoSize = lastWidth > 0 && lastHeight > 0 ? (lastWidth, lastHeight) : nil
    }

    /// 현재 창 크기를 새 메모 기본값으로 삼는다. 마음에 드는 크기를 잡아 두고 고정할 때 쓴다.
    public func setDefaultMemoSize(width: Double, height: Double) {
        defaultMemoWidth = max(width, Self.minimumMemoSize.width)
        defaultMemoHeight = max(height, Self.minimumMemoSize.height)
        hasChosenMemoSize = true
    }

    public func setFontSize(_ size: Double) {
        fontSize = size
        hasChosenFontSize = true
    }

    /// 화면 밀도에 맞춘 값을 적용한다.
    ///
    /// `force`가 false면 사용자가 한 번도 직접 고르지 않은 항목에만 적용한다.
    /// 첫 실행에서 화면에 맞는 값으로 시작하되, 사용자가 정한 값을 덮어쓰지 않기 위해서다.
    public func applyRecommended(fontSize newFontSize: Double, memoWidth: Double, memoHeight: Double, force: Bool = false) {
        if force || !hasChosenFontSize {
            fontSize = newFontSize
            hasChosenFontSize = force
        }
        if force || !hasChosenMemoSize {
            defaultMemoWidth = max(memoWidth, Self.minimumMemoSize.width)
            defaultMemoHeight = max(memoHeight, Self.minimumMemoSize.height)
            hasChosenMemoSize = force
        }
    }
}
