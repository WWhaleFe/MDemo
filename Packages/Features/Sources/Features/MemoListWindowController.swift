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
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "메모 목록"
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        // 메모 창들이 항상 위에 떠 있으므로, 리스트 창도 같은 높이에 두어야 가려지지 않는다.
        window.level = .floating

        self.window = window
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

    public func close() {
        window?.close()
    }

    /// 창을 닫으면 화면과 모델을 버린다.
    public func windowWillClose(_ notification: Notification) {
        if let controlClickMonitor {
            NSEvent.removeMonitor(controlClickMonitor)
        }
        controlClickMonitor = nil
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
