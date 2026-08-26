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

    public init(
        store: MemoStore,
        onOpenMemo: @escaping (MemoID) -> Void,
        onCreateMemo: @escaping () -> Void
    ) {
        self.store = store
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

        let model = MemoListModel(store: store)
        model.refresh()
        self.model = model

        let view = MemoListView(
            model: model,
            onOpenMemo: { [weak self] id in self?.onOpenMemo(id) },
            onCreateMemo: { [weak self] in self?.onCreateMemo() }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.close()
    }

    /// 창을 닫으면 화면과 모델을 버린다.
    public func windowWillClose(_ notification: Notification) {
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
