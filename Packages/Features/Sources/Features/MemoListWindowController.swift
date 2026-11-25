import AppKit
import MemoCore
import SwiftUI

/// 리스트 창의 수명을 관리한다 (LST-01).
///
/// 창을 닫으면 화면과 모델을 통째로 버린다.
/// 숨겨만 두면 SwiftUI 뷰 계층이 계속 메모리를 붙들고 있기 때문이다 (§4-5).
@MainActor
public final class MemoListWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: MemoListModel?

    private let store: MemoStore
    private let onOpenMemo: (MemoID) -> Void
    private let onCreateMemo: () -> Void
    /// 창을 띄우고 내리고 늘어놓는 일. 창 계층에서 주입한다 (LST-06 ~ LST-10).
    public var windowActions: MemoWindowActions
    /// 휴지통 자동 비우기 기한(일). 꺼져 있으면 nil.
    public var trashRetentionDays: () -> Int? = { nil }

    /// ⌃ 클릭을 ⌘ 클릭으로 바꿔 주는 감시자. 창이 떠 있는 동안만 둔다.
    private var controlClickMonitor: Any?
    /// "항상 위에" 설정이 바뀌면 창 높이를 바로 맞춘다. 창이 떠 있는 동안만 둔다.
    private var alwaysOnTopObserver: NSObjectProtocol?

    /// 목록 창을 다른 앱 창보다 항상 위에 둘지 저장하는 키. 목록 창의 핀 버튼과 메뉴바 설정이 같이 쓴다.
    public static let alwaysOnTopKey = "memoList.alwaysOnTop"

    /// 저장된 값이 없으면 끈다. 다른 앱이나 파일을 고를 때 목록 창이 가리지 않게 한다.
    public static var isAlwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysOnTopKey) }
        set { UserDefaults.standard.set(newValue, forKey: alwaysOnTopKey) }
    }

    public init(
        store: MemoStore,
        windowActions: MemoWindowActions = .none,
        onOpenMemo: @escaping (MemoID) -> Void,
        onCreateMemo: @escaping () -> Void
    ) {
        self.store = store
        self.windowActions = windowActions
        self.onOpenMemo = onOpenMemo
        self.onCreateMemo = onCreateMemo
        super.init()
    }

    public var isOpen: Bool { window != nil }

    /// 이미 떠 있으면 앞으로 가져오고, 없으면 새로 만든다 (KEY-13).
    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = MemoListModel(store: store, windowActions: windowActions)
        model.trashRetentionDays = trashRetentionDays
        model.refresh()
        self.model = model

        let view = MemoListView(
            model: model,
            onOpenMemo: { [weak self] id in self?.onOpenMemo(id) },
            onCreateMemo: { [weak self] in self?.onCreateMemo() }
        )

        let window = NSWindow(
            // 버튼 줄이 한 줄에 다 들어가는 너비로 연다.
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "메모 목록"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 820, height: 520)
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        // 켜 두면 메모 창과 같은 높이에 떠서 가려지지 않고, 끄면 보통 창처럼 다른 앱 뒤로 간다.
        applyAlwaysOnTop(to: window)

        self.window = window
        alwaysOnTopObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.applyAlwaysOnTop(to: window)
            }
        }
        installControlClickSelection()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 목록에서 ⌃ 클릭으로도 하나씩 골라 담을 수 있게 한다 (LST-05).
    ///
    /// 맥에서 ⌃ 클릭은 우클릭과 같아 메뉴가 뜨지만, Windows에 익숙한 손은 Ctrl로 여러 개를 고른다.
    /// 이 창 안에서만 ⌃ 클릭을 ⌘ 클릭으로 바꿔 넘긴다. 우클릭 메뉴는 오른쪽 버튼으로 그대로 열린다.
    private func installControlClickSelection() {
        controlClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let window = self?.window, event.window === window else { return event }
            let flags = event.modifierFlags
            guard flags.contains(.control), !flags.contains(.command) else { return event }

            let converted = flags.subtracting(.control).union(.command)
            return NSEvent.mouseEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: converted,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                eventNumber: event.eventNumber,
                clickCount: event.clickCount,
                pressure: event.pressure
            ) ?? event
        }
    }

    private func applyAlwaysOnTop(to window: NSWindow) {
        let level: NSWindow.Level = Self.isAlwaysOnTop ? .floating : .normal
        if window.level != level { window.level = level }
    }

    public func close() {
        window?.close()
    }

    /// 창을 닫으면 화면과 모델을 버린다.
    public func windowWillClose(_ notification: Notification) {
        // 목록 창이 닫히면 목록에서 받던 AirDrop도 멈춘다.
        model?.stopAirDrop()
        if let controlClickMonitor {
            NSEvent.removeMonitor(controlClickMonitor)
        }
        controlClickMonitor = nil
        if let alwaysOnTopObserver {
            NotificationCenter.default.removeObserver(alwaysOnTopObserver)
        }
        alwaysOnTopObserver = nil
        window?.contentView = nil
        window?.delegate = nil
        window = nil
        model = nil
    }

    /// 메모가 바뀌었을 때 목록을 다시 읽는다. 창이 닫혀 있으면 아무 일도 하지 않는다.
    public func refreshIfOpen() {
        model?.refresh()
    }
}
