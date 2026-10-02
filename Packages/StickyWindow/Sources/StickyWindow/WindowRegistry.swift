import AppKit
import EditorKit
import MemoCore
import Services

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
    private let preferences: AppPreferences

    /// 창이 뜨거나 지거나 숨겨졌을 때. 리스트 창의 "보이는/숨겨진" 개수를 맞추는 데 쓴다.
    public var onWindowStateChange: (() -> Void)?

    public init(store: MemoStore, deviceState: DeviceStateStore, preferences: AppPreferences) {
        self.store = store
        self.deviceState = deviceState
        self.preferences = preferences
    }

    public var openCount: Int { controllers.count }

    /// 환경설정을 반영한 현재 테마.
    private var currentTheme: EditorTheme {
        EditorTheme(
            fontFamily: preferences.fontFamily,
            baseFontSize: preferences.fontSize,
            textColor: .black
        )
    }

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
            existing.setHidden(false)
            existing.show()
            onWindowStateChange?()
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

    /// 동기화로 파일이 바뀐 뒤, 화면에 떠 있는 창을 파일 상태에 맞춘다 (SYNC-08).
    ///
    /// 다른 기기에서 띄운 메모는 여기서도 뜨고, 저쪽에서 닫은 메모는 여기서도 닫힌다.
    /// "무엇이 떠 있는가"만 맞추고 "어디에 떠 있는가"는 기기별로 그대로 둔다 (SYNC-07).
    public func reconcileOpenWindows(with store: MemoStore) {
        let shouldBeOpen = Set(store.openMemos.map(\.id))
        let currentlyOpen = Set(controllers.keys)

        for id in shouldBeOpen.subtracting(currentlyOpen) {
            openMemo(id: id)
        }
        for id in currentlyOpen.subtracting(shouldBeOpen) {
            // 사라진 메모(다른 기기에서 버린 경우)도 여기서 닫힌다.
            controllers[id]?.closeWithoutMarkingClosed()
            controllers.removeValue(forKey: id)
        }

        // 다른 기기에서 고친 내용이 열려 있는 창에도 보여야 한다.
        for (id, controller) in controllers where shouldBeOpen.contains(id) {
            controller.reloadBodyFromStore()
        }
    }

    private func present(meta: MemoMeta, body: String, frame: NSRect) {
        let controller = StickyWindowController(
            meta: meta,
            body: body,
            frame: frame,
            theme: currentTheme,
            toolbarPosition: preferences.formatToolbarPosition,
            store: store,
            deviceState: deviceState
        )
        controller.onClose = { [weak self] id in
            self?.release(id)
        }
        // 서식 막대의 글자 크기 버튼은 전역 설정을 바꾼다. 열려 있는 창 전부에 함께 반영한다.
        controller.onRequestFontStep = { [weak self] delta in
            self?.stepFontSize(by: delta)
        }
        // 마지막으로 크기를 맞춘 창을 기록한다. 새 메모에 쓸지는 설정이 정한다 (SET-01).
        controller.onUserResized = { [weak self] size in
            self?.preferences.recordResizedMemoSize(width: size.width, height: size.height)
        }
        controller.setHoverOpaqueEnabled(preferences.hoverOpaque)
        controllers[meta.id] = controller
        controller.show()
        // 접힌 채로 닫았다면 그대로 되살린다 (WIN-08).
        controller.restoreCollapsedStateIfNeeded()
        onWindowStateChange?()
    }

    // MARK: - 환경설정 반영

    /// 글꼴·크기 설정이 바뀌면 열려 있는 모든 창에 즉시 적용한다 (TXT-02, TXT-03).
    public func applyPreferencesToOpenWindows() {
        let theme = currentTheme
        for controller in controllers.values {
            controller.applyTheme(theme)
            controller.setHoverOpaqueEnabled(preferences.hoverOpaque)
            controller.setToolbarPosition(preferences.formatToolbarPosition)
        }
    }

    /// 글자 크기를 한 단계 올리거나 내린다 (TXT-03).
    ///
    /// 서식 막대의 A- / A+ 버튼이 쓴다. 단계는 메뉴의 글자 크기 목록과 같은 것을 쓴다 —
    /// 두 곳에서 다른 값이 나오면 설정이 어긋나 보인다.
    public func stepFontSize(by delta: Int) {
        let steps = EditorTheme.fontSizeSteps
        let current = steps.firstIndex { abs(Double($0) - preferences.fontSize) < 0.5 }
            ?? steps.firstIndex { Double($0) > preferences.fontSize }
            ?? steps.count - 1
        let next = max(0, min(current + delta, steps.count - 1))
        guard next != current || abs(Double(steps[next]) - preferences.fontSize) >= 0.5 else { return }
        preferences.setFontSize(Double(steps[next]))
        applyPreferencesToOpenWindows()
    }

    /// 맨 앞 창의 크기를 새 메모 기본 크기로 삼는다 (SET-01).
    /// 마음에 드는 크기를 손으로 잡아 두고 그대로 고정하고 싶을 때 쓴다.
    @discardableResult
    /// 사용자가 창 크기를 끌어 바꾼 것과 같은 경로를 태운다. 시험용.
    public func simulateUserResize(id: MemoID, to size: NSSize) {
        controllers[id]?.resizeAsUser(to: size)
    }

    public func adoptFrontmostSizeAsDefault() -> Bool {
        guard let frame = frontmostFrame() else { return false }
        preferences.setDefaultMemoSize(width: frame.width, height: frame.height)
        return true
    }

    /// 맨 앞 메모에 글자를 넣는다. 실행 인자로 동작을 확인할 때 쓴다.
    public func insertTextInFrontmostMemo(_ text: String) {
        if let key = NSApp.keyWindow, let controller = controllers.values.first(where: { $0.owns(key) }) {
            controller.insertText(text)
            return
        }
        controllers.values.first?.insertText(text)
    }

    // MARK: - 창 조작
    //
    // 메뉴·버튼이 하는 일을 코드로도 부를 수 있게 열어 둔다.
    // 창 동작은 눈으로만 확인하기 쉬운데, 그러면 고칠 때마다 놓치는 곳이 생긴다.

    public func toggleCollapsed(id: MemoID) {
        controllers[id]?.toggleCollapsed()
    }

    public func setColor(_ hex: String, for id: MemoID) {
        controllers[id]?.setColor(hex)
    }

    public func setBackgroundAlpha(_ value: Double, for id: MemoID) {
        controllers[id]?.setBackgroundAlpha(value)
    }

    public func setTextAlpha(_ value: Double, for id: MemoID) {
        controllers[id]?.setTextAlpha(value)
    }

    public func setPinned(_ isPinned: Bool, for id: MemoID) {
        controllers[id]?.setPinned(isPinned)
    }

    /// 메모 제목을 바꾼다 (TXT-06).
    public func setTitle(_ title: String?, for id: MemoID) {
        controllers[id]?.setTitle(title)
    }

    public func title(of id: MemoID) -> String? {
        controllers[id]?.currentTitle
    }

    public func titleFont(of id: MemoID) -> NSFont? {
        controllers[id]?.titleFont
    }

    public func closeMemo(id: MemoID) {
        controllers[id]?.close()
    }

    /// 서식 막대의 버튼을 누른 것과 같은 경로를 태운다 (FMT-01).
    public func performToolbarCommand(_ command: FormatToolbarView.Command, in id: MemoID) {
        controllers[id]?.handleToolbarCommand(command)
    }

    /// 서식 막대의 버튼에 마우스를 올린 것과 같은 경로를 태운다 (FMT-05).
    public func simulateToolbarHover(index: Int, in id: MemoID, isInside: Bool = true) {
        controllers[id]?.simulateToolbarHover(index: index, isInside: isInside)
    }

    public func toolbarButtonCount(of id: MemoID) -> Int? {
        controllers[id]?.toolbarButtonCount
    }

    public func toolbarPosition(of id: MemoID) -> FormatToolbarPosition? {
        controllers[id]?.currentToolbarPosition
    }

    /// 화면에 보이는 본문을 마크다운으로. 서식이 실제로 들어갔는지 확인할 때 쓴다.
    public func bodyMarkdown(of id: MemoID) -> String? {
        controllers[id]?.currentBodyMarkdown
    }

    public func frame(of id: MemoID) -> NSRect? {
        controllers[id]?.currentFrame
    }

    public func windowLevel(of id: MemoID) -> NSWindow.Level? {
        controllers[id]?.windowLevel
    }

    /// 특정 메모에 글자를 넣는다. 실행 중인 앱에서 그리기를 확인할 때 쓴다.
    public func insertText(_ text: String, in id: MemoID) {
        controllers[id]?.insertText(text)
    }

    /// 특정 메모에서 Tab을 누른 것과 같은 경로를 태운다 (표의 칸 이동 확인용).
    public func simulateTabKey(in id: MemoID) {
        controllers[id]?.simulateTabKey()
    }

    /// 특정 메모에서 엔터를 누른 것과 같은 경로를 태운다.
    public func simulateReturnKey(in id: MemoID) {
        controllers[id]?.simulateReturnKey()
    }

    /// 맨 앞 메모에서 엔터를 누른 것과 같은 경로를 태운다.
    public func simulateReturnKeyInFrontmostMemo() {
        controllers.values.first?.simulateReturnKey()
    }

    /// 슬래시 팝업의 실제 치수. 계산과 화면이 어긋날 때 확인용.
    public var slashPopupDiagnostics: String {
        controllers.values.first?.slashPopupDiagnostics ?? "열린 메모 없음"
    }

    private func frontmostFrame() -> NSRect? {
        if let key = NSApp.keyWindow, controllers.values.contains(where: { $0.owns(key) }) {
            return key.frame
        }
        return controllers.values.first?.currentFrame
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
            width: max(state.frame[2], AppPreferences.minimumMemoSize.width),
            height: max(state.frame[3], AppPreferences.minimumMemoSize.height)
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
        let newSize = preferences.newMemoSize
        let size = NSSize(width: newSize.width, height: newSize.height)
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
        onWindowStateChange?()
    }

    // MARK: - 리스트 창에서 부르는 창 조작 (LST-06, LST-09 ~ LST-11)

    /// 그 메모의 창이 지금 화면에 보이는가.
    ///
    /// "숨김"은 창을 지운 것이 아니라 화면에서 내린 것이다.
    /// 한 번도 열지 않은 메모와 내려 둔 메모는 리스트에서 똑같이 "숨겨진 메모"로 다룬다 (LST-09).
    public func isVisible(id: MemoID) -> Bool {
        controllers[id]?.isWindowVisible ?? false
    }

    /// 지금 화면에 보이는 메모들.
    public var visibleMemoIDs: Set<MemoID> {
        Set(controllers.filter { $0.value.isWindowVisible }.keys)
    }

    /// 고른 메모들을 화면에 띄운다 (LST-10).
    public func openMemos(ids: [MemoID]) {
        defer { onWindowStateChange?() }
        for id in ids {
            if let existing = controllers[id] {
                // 내려 둔 창은 다시 올리기만 하면 된다. 본문을 또 읽을 이유가 없다.
                existing.setHidden(false)
                existing.show()
            } else {
                openMemo(id: id)
            }
        }
    }

    /// 고른 메모들을 화면에서 내린다 (LST-10).
    ///
    /// 창과 본문은 그대로 두고 화면에서만 내린다. 다시 띄울 때 파일을 읽지 않아도 된다.
    public func hideMemos(ids: [MemoID]) {
        for id in ids {
            controllers[id]?.setHidden(true)
        }
        onWindowStateChange?()
    }

    /// 떠 있는 창을 화면에 격자로 늘어놓는다 (LST-06, LST-11).
    ///
    /// 창이 여러 개 겹치면 무엇이 어디 있는지 알 수 없다. 한 번에 펼쳐 보는 길을 둔다.
    /// `byGroup`이면 그룹마다 줄을 나눠, 같은 그룹이 가로로 이어지게 놓는다.
    public func arrangeOpenWindows(byGroup: Bool) {
        let visible = controllers.filter { $0.value.isWindowVisible }
        guard !visible.isEmpty else { return }

        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 12

        // 무엇을 어느 줄에 놓을지 먼저 정한다. 배치 계산은 그다음이다.
        let rows: [[StickyWindowController]]
        if byGroup {
            let groupOf = Dictionary(
                uniqueKeysWithValues: store.summaries.map { ($0.id, $0.meta.group) }
            )
            let buckets = Dictionary(grouping: visible.values) { groupOf[$0.memoID] ?? nil }
            // 그룹 없음(nil)은 맨 뒤로 보낸다.
            rows = buckets.keys
                .sorted { ($0 ?? "\u{10FFFF}") < ($1 ?? "\u{10FFFF}") }
                .map { buckets[$0] ?? [] }
        } else {
            let all = Array(visible.values)
            let columns = max(1, Int(ceil(Double(all.count).squareRoot())))
            rows = stride(from: 0, to: all.count, by: columns).map {
                Array(all[$0..<min($0 + columns, all.count)])
            }
        }

        let rowHeight = (screen.height - gap * CGFloat(rows.count + 1)) / CGFloat(rows.count)
        for (rowIndex, row) in rows.enumerated() where !row.isEmpty {
            let width = (screen.width - gap * CGFloat(row.count + 1)) / CGFloat(row.count)
            let top = screen.maxY - gap - CGFloat(rowIndex) * (rowHeight + gap)

            for (columnIndex, controller) in row.enumerated() {
                let x = screen.minX + gap + CGFloat(columnIndex) * (width + gap)
                // 접어 둔 창은 높이를 건드리지 않는다. 펼쳐 놓으면 접어 둔 뜻이 사라진다.
                let height = controller.isWindowCollapsed ? controller.currentFrame.height : rowHeight
                controller.setFrame(NSRect(
                    x: x,
                    y: top - height,
                    width: max(width, AppPreferences.minimumMemoSize.width),
                    height: max(height, AppPreferences.minimumMemoSize.height)
                ))
            }
        }
    }

    /// 한 번에 감췄다 보였다 한다 (SYS-04).
    /// 화면을 잠깐 치우고 싶을 때 쓰는 기능이라, 상태를 기억했다가 되돌린다.
    public func toggleAllHidden() {
        let anyVisible = controllers.values.contains { $0.isWindowVisible }
        setAllHidden(anyVisible)
    }

    /// 모든 메모 창 숨기기/보이기 (SYS-04). 컨트롤러는 유지된다.
    public func setAllHidden(_ hidden: Bool) {
        for controller in controllers.values {
            controller.setHidden(hidden)
        }
        onWindowStateChange?()
    }

    /// 모든 창을 닫고 해제한다.
    public func closeAll() {
        for controller in controllers.values {
            controller.close()
        }
        controllers.removeAll()
        onWindowStateChange?()
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
