import AppKit
import MemoCore

/// 열려 있는 스티키 창을 관리한다 (WIN-01, WIN-05/06).
///
/// 여기 담긴 컨트롤러 수 = 메모리에 본문이 올라와 있는 메모 수다.
/// 창을 닫으면 즉시 제거해 메모리를 회수한다 (NFR-10).
@MainActor
public final class WindowRegistry {
    private var controllers: [MemoID: StickyWindowController] = [:]
    private var nextCascadeOffset: CGFloat = 0

    public init() {}

    public var openCount: Int { controllers.count }

    /// 새 메모 창을 띄운다 (KEY-10).
    @discardableResult
    public func createMemo(color: MemoColor = MemoColor.presets[0]) -> MemoID {
        let meta = MemoMeta(id: .generate(), colorHex: color.hex)
        let controller = StickyWindowController(meta: meta, frame: nextFrame())
        controller.onClose = { [weak self] id in
            self?.release(id)
        }
        controllers[meta.id] = controller
        controller.show()
        return meta.id
    }

    /// 창이 정확히 겹치지 않도록 조금씩 어긋나게 배치한다.
    private func nextFrame() -> NSRect {
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

    /// 모든 창을 닫고 해제한다. 메모리 회수 확인용 경로이기도 하다.
    public func closeAll() {
        for controller in controllers.values {
            controller.close()
        }
        controllers.removeAll()
    }
}
