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

    public static let defaultFontSize: Double = 15
    public static let defaultMemoSize = (width: 320.0, height: 340.0)
    /// 창이 너무 작아 내용을 볼 수 없게 되는 것을 막는다.
    public static let minimumMemoSize = (width: 180.0, height: 120.0)

    @ObservationIgnored private let store: UserDefaults

    private enum Key {
        static let fontFamily = "editor.fontFamily"
        static let fontSize = "editor.fontSize"
        static let defaultMemoWidth = "memo.defaultWidth"
        static let defaultMemoHeight = "memo.defaultHeight"
    }

    public init(store: UserDefaults = .standard) {
        self.store = store
        self.fontFamily = store.string(forKey: Key.fontFamily)

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
    }
}
