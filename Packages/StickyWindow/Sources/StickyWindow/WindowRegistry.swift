import AppKit
import MemoCore

/// 열려 있는 스티키 창을 관리한다 (WIN-01, WIN-05/06).
///
/// 여기 담긴 컨트롤러 수 = 본문이 메모리에 올라와 있는 메모 수다.
/// 창을 닫으면 즉시 제거해 메모리를 회수한다 (NFR-10).
@MainActor
public final class WindowRegistry {
    private var controllers: [MemoID: StickyWindowController] = [:]
    private var nextCascadeOffset: CGFloat = 0

    private let store: MemoStore
    private let deviceState: DeviceStateStore

    public init(store: MemoStore, deviceState: DeviceStateStore) {
        self.store = store
        self.deviceState = deviceState
    }

    public var openCount: Int { controllers.count }

    /// 새 메모를 만들고 창을 띄운다 (KEY-10).
    @discardableResult
    public func createMemo(color: MemoColor = MemoColor.presets[0]) -> MemoID {
        let meta = store.createMemo(colorHex: color.hex)
        present(meta: meta, body: "", frame: cascadeFrame())
        return meta.id
    }

    /// 이미 있는 메모를 화면에 띄운다. 본문은 이때 처음 읽는다 (LST-04).
    public func openMemo(id: MemoID) {
        if let existing = controllers[id] {
            existing.show()
            return
        }
        guard let document = store.loadDocument(id: id) else { return }
        present(meta: document.meta, body: document.body, frame: restoredFrame(for: id))
        store.setOpen(id: id, isOpen: true)
    }

    /// 앱 시작 시, 지난번에 열려 있던 메모를 그대로 되살린다 (WIN-06).
    public func restoreOpenMemos() {
        for summary in store.openMemos {
            openMemo(id: summary.id)
        }
    }

    private func present(meta: MemoMeta, body: String, frame: NSRect) {
        let controller = StickyWindowController(
            meta: meta,
            body: body,
            frame: frame,
            store: store,
            deviceState: deviceState
        )
        controller.onClose = { [weak self] id in
            self?.release(id)
        }
        controllers[meta.id] = controller
        controller.show()
    }

    // MARK: - 창 위치

    /// 저장된 위치를 되살리되, 그 사이 모니터 구성이 바뀌었을 수 있으므로 화면 안으로 보정한다 (SYS-05).
    private func restoredFrame(for id: MemoID) -> NSRect {
        guard let state = deviceState.state(for: id), state.frame.count == 4 else {
            return cascadeFrame()
        }
        let saved = NSRect(
            x: state.frame[0],
            y: state.frame[1],
            width: max(state.frame[2], 180),
            height: max(state.frame[3], 120)
        )
        return Self.clampToVisibleScreen(saved) ?? cascadeFrame()
    }

    /// 창이 어느 화면과도 겹치지 않으면(모니터를 뺀 경우) 주 화면 안으로 되돌린다.
    static func clampToVisibleScreen(_ frame: NSRect) -> NSRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        // 창의 일부라도 보이면 그대로 둔다.
        if screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            return frame
        }

        guard let main = NSScreen.main?.visibleFrame else { return nil }
        var corrected = frame
        corrected.size.width = min(frame.width, main.width)
        corrected.size.height = min(frame.height, main.height)
        corrected.origin.x = min(max(main.minX, frame.origin.x), main.maxX - corrected.width)
        corrected.origin.y = min(max(main.minY, frame.origin.y), main.maxY - corrected.height)
        return corrected
    }

    /// 새 창이 정확히 겹치지 않도록 조금씩 어긋나게 배치한다.
    private func cascadeFrame() -> NSRect {
        let size = NSSize(width: 300, height: 320)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screen.maxX - size.width - 60 - nextCascadeOffset,
            y: screen.maxY - size.height - 60 - nextCascadeOffset
        )
        nextCascadeOffset = (nextCascadeOffset + 24).truncatingRemainder(dividingBy: 240)
        return NSRect(origin: origin, size: size)
    }

    private func release(_ id: MemoID) {
        controllers.removeValue(forKey: id)
    }

    /// 모든 메모 창 숨기기/보이기 (SYS-04). 컨트롤러는 유지된다.
    public func setAllHidden(_ hidden: Bool) {
        for controller in controllers.values {
            controller.setHidden(hidden)
        }
    }

    /// 모든 창을 닫고 해제한다.
    public func closeAll() {
        for controller in controllers.values {
            controller.close()
        }
        controllers.removeAll()
    }

    /// 앱이 종료되기 전에 열린 창의 내용을 모두 확실히 기록한다.
    /// 열림 상태는 그대로 두어야 다음 실행에서 복원된다 (WIN-06).
    public func flushAllBeforeTermination() {
        for controller in controllers.values {
            controller.flushBeforeTermination()
        }
        deviceState.flush()
    }
}
