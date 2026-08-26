import Foundation
import Observation

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
        self.hasChosenFontSize = store.object(forKey: Key.fontSize) != nil
        self.hasChosenMemoSize = store.object(forKey: Key.defaultMemoWidth) != nil

        let savedSize = store.double(forKey: Key.fontSize)
        self.fontSize = savedSize > 0 ? savedSize : Self.defaultFontSize

        let savedWidth = store.double(forKey: Key.defaultMemoWidth)
        self.defaultMemoWidth = savedWidth > 0 ? savedWidth : Self.defaultMemoSize.width

        let savedHeight = store.double(forKey: Key.defaultMemoHeight)
        self.defaultMemoHeight = savedHeight > 0 ? savedHeight : Self.defaultMemoSize.height
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
