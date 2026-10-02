import AppKit
import EditorKit
import MarkdownEngine
import MemoCore
import Services
import StickyWindow
import TestKit

// 창 동작은 눈으로만 확인하기 쉬운데, 그러면 고칠 때마다 놓치는 곳이 생긴다.
// 창을 실제로 만들어 크기·접기·투명도가 값으로 어떻게 남는지 확인한다.

let runner = TestRunner("StickyWindow")

@MainActor
func makeRegistry() throws -> (WindowRegistry, MemoStore, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("StickyWindowTests-\(UUID().uuidString)", isDirectory: true)
    let repository = try FileMemoRepository(rootDirectory: root)
    let store = MemoStore(repository: repository)
    let deviceState = DeviceStateStore(fileURL: root.appendingPathComponent("device-state.json"))
    let preferences = AppPreferences(store: UserDefaults(suiteName: root.lastPathComponent)!)
    return (WindowRegistry(store: store, deviceState: deviceState, preferences: preferences), store, root)
}

@MainActor
func makeRegistryWithPreferences() throws -> (WindowRegistry, MemoStore, URL, AppPreferences) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("StickyWindowTests-\(UUID().uuidString)", isDirectory: true)
    let repository = try FileMemoRepository(rootDirectory: root)
    let store = MemoStore(repository: repository)
    let deviceState = DeviceStateStore(fileURL: root.appendingPathComponent("device-state.json"))
    let preferences = AppPreferences(store: UserDefaults(suiteName: root.lastPathComponent)!)
    let registry = WindowRegistry(store: store, deviceState: deviceState, preferences: preferences)
    return (registry, store, root, preferences)
}

runner.test("새 메모 창은 설정한 기본 크기로 열린다 (SET-01)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        t.expectEqual(registry.openCount, 1)

        let frame = registry.frame(of: id)
        t.expectNotNil(frame, "창을 찾지 못했다")
        t.expect((frame?.width ?? 0) >= AppPreferences.minimumMemoSize.width, "창이 최소 크기보다 작다")
    }
}

runner.test("접으면 제목 줄만 남고 다시 펼치면 원래 높이로 돌아온다 (WIN-08)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        let expanded = registry.frame(of: id)?.height ?? 0
        t.expect(expanded > 100, "펼친 높이가 이상하다: \(expanded)")

        registry.toggleCollapsed(id: id)
        let collapsed = registry.frame(of: id)?.height ?? 0
        t.expect(collapsed < expanded, "접히지 않았다 (\(collapsed) vs \(expanded))")
        // 버튼 줄 + 간격 + 제목 줄. 본문이 한 줄이라도 남으면 이보다 커진다.
        t.expect(collapsed <= 75, "제목 줄만 남아야 한다: \(collapsed)")

        registry.toggleCollapsed(id: id)
        t.expectEqual(registry.frame(of: id)?.height, expanded, "펼쳤을 때 원래 높이로 돌아오지 않았다")
    }
}

runner.test("접힌 채로 닫아도 창 위치는 펼친 높이로 저장된다 (WIN-05, WIN-08)") { t in
    try MainActor.assumeIsolated {
        let (registry, store, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        let expanded = registry.frame(of: id)?.height ?? 0

        registry.toggleCollapsed(id: id)
        registry.flushAllBeforeTermination()

        let deviceState = DeviceStateStore(fileURL: root.appendingPathComponent("device-state.json"))
        let saved = deviceState.state(for: id)
        t.expectNotNil(saved, "창 상태가 저장되지 않았다")
        t.expectEqual(saved?.frame[3], expanded, "접힌 높이가 저장되면 다음에 열 때 찌그러진다")
        t.expectEqual(saved?.isCollapsed, true, "접힌 상태가 기록되지 않았다")
        _ = store
    }
}

runner.test("투명도를 바꾸면 파일에 남고 하한선이 지켜진다 (OPA-01~03)") { t in
    try MainActor.assumeIsolated {
        let (registry, store, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        registry.setBackgroundAlpha(0.0, for: id)   // 하한선 아래로 밀어 본다
        registry.setTextAlpha(0.0, for: id)

        let saved = store.loadDocument(id: id)?.meta
        t.expectEqual(saved?.backgroundAlpha, MemoMeta.backgroundAlphaRange.lowerBound, "배경 알파 하한선이 지켜지지 않았다")
        t.expectEqual(saved?.textAlpha, MemoMeta.textAlphaRange.lowerBound, "글자 알파 하한선이 지켜지지 않았다")

        registry.setBackgroundAlpha(0.6, for: id)
        t.expectEqual(store.loadDocument(id: id)?.meta.backgroundAlpha, 0.6, "투명도가 저장되지 않았다")
    }
}

runner.test("배경색을 바꾸면 파일에 남는다 (WIN-11)") { t in
    try MainActor.assumeIsolated {
        let (registry, store, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        let mint = MemoColor.presets[5]
        registry.setColor(mint.hex, for: id)

        t.expectEqual(store.loadDocument(id: id)?.meta.colorHex, mint.hex)
    }
}

runner.test("항상 위 토글이 창 레벨과 파일에 모두 반영된다 (WIN-03)") { t in
    try MainActor.assumeIsolated {
        let (registry, store, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        registry.setPinned(false, for: id)
        t.expectEqual(store.loadDocument(id: id)?.meta.isPinned, false)
        t.expectEqual(registry.windowLevel(of: id), NSWindow.Level.normal)

        registry.setPinned(true, for: id)
        t.expectEqual(store.loadDocument(id: id)?.meta.isPinned, true)
        t.expectEqual(registry.windowLevel(of: id), NSWindow.Level.floating)
    }
}

runner.test("창을 닫으면 컨트롤러가 해제된다 (NFR-10)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        t.expectEqual(registry.openCount, 1)

        registry.closeMemo(id: id)
        t.expectEqual(registry.openCount, 0, "닫았는데 컨트롤러가 남아 있다 — 본문이 메모리에 계속 있다는 뜻")
    }
}

runner.test("서식 막대 버튼이 단축키와 같은 서식을 넣는다 (FMT-01)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        registry.insertTextInFrontmostMemo("장보기")

        registry.performToolbarCommand(.block(.checkbox(indent: 0, checked: false)), in: id)
        t.expect(registry.bodyMarkdown(of: id)?.hasPrefix("- [ ] ") == true,
                 "체크박스가 되지 않았다: \(registry.bodyMarkdown(of: id) ?? "없음")")

        registry.performToolbarCommand(.block(.heading(level: 1)), in: id)
        t.expect(registry.bodyMarkdown(of: id)?.hasPrefix("# ") == true,
                 "제목이 되지 않았다: \(registry.bodyMarkdown(of: id) ?? "없음")")
    }
}

runner.test("서식 막대 자리는 설정을 따라 옮겨진다 (FMT-02, SET-08)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root, preferences) = try makeRegistryWithPreferences()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        t.expectEqual(registry.toolbarPosition(of: id), .top, "기본값은 위쪽이어야 한다")

        preferences.formatToolbarPosition = .bottom
        registry.applyPreferencesToOpenWindows()
        t.expectEqual(registry.toolbarPosition(of: id), .bottom)

        // 좌우로도 세울 수 있다 (FMT-04).
        preferences.formatToolbarPosition = .left
        registry.applyPreferencesToOpenWindows()
        t.expectEqual(registry.toolbarPosition(of: id), .left)
        t.expect(FormatToolbarPosition.left.isVertical, "왼쪽 막대는 세로로 서야 한다")

        preferences.formatToolbarPosition = .right
        registry.applyPreferencesToOpenWindows()
        t.expectEqual(registry.toolbarPosition(of: id), .right)

        preferences.formatToolbarPosition = .hidden
        registry.applyPreferencesToOpenWindows()
        t.expectEqual(registry.toolbarPosition(of: id), .hidden)
    }
}

runner.test("서식 막대의 글자 크기 버튼은 한 단계씩 오르내린다 (TXT-03)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root, preferences) = try makeRegistryWithPreferences()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        let steps = EditorTheme.fontSizeSteps.map(Double.init)
        preferences.setFontSize(steps[2])

        registry.performToolbarCommand(.fontStep(delta: 1), in: id)
        t.expectEqual(preferences.fontSize, steps[3], "한 단계 커지지 않았다")

        registry.performToolbarCommand(.fontStep(delta: -1), in: id)
        t.expectEqual(preferences.fontSize, steps[2], "한 단계 작아지지 않았다")

        // 끝에서는 더 가지 않는다.
        preferences.setFontSize(steps[steps.count - 1])
        registry.performToolbarCommand(.fontStep(delta: 1), in: id)
        t.expectEqual(preferences.fontSize, steps[steps.count - 1], "가장 큰 단계를 넘어갔다")
    }
}

runner.test("창 나열은 겹치지 않게 화면 안에 늘어놓는다 (LST-06)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let ids = (0..<4).map { _ in registry.createMemo() }
        registry.arrangeOpenWindows(byGroup: false)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frames = ids.compactMap { registry.frame(of: $0) }
        t.expectEqual(frames.count, 4)

        for frame in frames {
            t.expect(screen.insetBy(dx: -1, dy: -1).contains(frame), "창이 화면 밖으로 나갔다: \(frame)")
        }
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] where frame.intersects(other) {
                t.expect(false, "창이 겹쳤다: \(frame) / \(other)")
            }
        }
    }
}

runner.test("띄우기와 숨기기는 창을 지우지 않는다 (LST-10)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        t.expect(registry.isVisible(id: id), "새 메모는 화면에 떠야 한다")

        registry.hideMemos(ids: [id])
        t.expect(!registry.isVisible(id: id), "숨겨지지 않았다")
        t.expectEqual(registry.openCount, 1, "숨기기가 창을 해제했다 — 다시 띄울 때 파일을 또 읽게 된다")

        registry.openMemos(ids: [id])
        t.expect(registry.isVisible(id: id), "다시 띄워지지 않았다")
    }
}

runner.test("제목을 붙이면 파일과 목록에 함께 남는다 (TXT-06)") { t in
    try MainActor.assumeIsolated {
        let (registry, store, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        registry.insertTextInFrontmostMemo("첫 줄이 제목 노릇을 하던 자리")
        registry.setTitle("장보기", for: id)

        t.expectEqual(registry.title(of: id), "장보기")
        t.expectEqual(store.loadDocument(id: id)?.meta.title, "장보기", "파일에 제목이 남지 않았다")
        t.expectEqual(store.summaries.first(where: { $0.id == id })?.title, "장보기", "목록에 제목이 반영되지 않았다")

        // 비우면 다시 본문 첫 줄이 제목 노릇을 한다.
        registry.setTitle("", for: id)
        t.expectEqual(registry.title(of: id), nil)
        t.expectEqual(store.loadDocument(id: id)?.meta.title, nil)
    }
}

runner.test("코드 박스 버튼은 본문을 코드로 감싼다 (MD-10)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        registry.insertTextInFrontmostMemo("let x = 1")
        registry.performToolbarCommand(.block(.codeBlock), in: id)

        t.expectEqual(registry.bodyMarkdown(of: id), "```\nlet x = 1\n```",
                      "코드 박스로 저장되지 않았다: \(registry.bodyMarkdown(of: id) ?? "없음")")
    }
}

runner.test("버튼 이름표가 떠도 창 크기는 그대로다 (FMT-05)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root, preferences) = try makeRegistryWithPreferences()
        defer { try? FileManager.default.removeItem(at: root) }

        // 아래쪽 막대에서 오른쪽 끝 버튼 — 창이 갑자기 넓어지던 자리다.
        preferences.formatToolbarPosition = .bottom
        let id = registry.createMemo()
        let before = registry.frame(of: id)

        guard let count = registry.toolbarButtonCount(of: id), count > 0 else {
            t.expect(false, "서식 막대에 버튼이 없다")
            return
        }
        registry.simulateToolbarHover(index: count - 1, in: id)

        t.expectEqual(registry.frame(of: id), before, "이름표가 뜨면서 창 크기가 달라졌다")

        // 왼쪽 끝 버튼도 마찬가지다.
        registry.simulateToolbarHover(index: 0, in: id)
        t.expectEqual(registry.frame(of: id), before, "이름표가 뜨면서 창 크기가 달라졌다")
    }
}

runner.test("제목은 늘 굵고, 본문 글자 크기를 바꿔도 크기가 그대로다 (TXT-06)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = registry.createMemo()
        let before = registry.titleFont(of: id)
        t.expectNotNil(before)
        t.expect(before.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true,
                 "제목이 굵지 않다: \(String(describing: before))")

        registry.stepFontSize(by: 2)
        let after = registry.titleFont(of: id)
        t.expectEqual(after?.pointSize, before?.pointSize, "글자 크기를 바꾸자 제목 크기가 따라 바뀌었다")
        t.expect(after.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true,
                 "글자 크기를 바꾸자 제목이 굵지 않게 됐다")
    }
}

runner.test("크기를 맞추면 그 크기로 새 메모가 열리고, 기능을 끄면 기본 크기로 연다 (SET-01)") { t in
    try MainActor.assumeIsolated {
        let (registry, _, root, preferences) = try makeRegistryWithPreferences()
        defer { try? FileManager.default.removeItem(at: root) }
        preferences.setDefaultMemoSize(width: 420, height: 480)
        t.expect(preferences.rememberLastMemoSize, "기본으로 켜져 있어야 한다")

        let first = registry.createMemo()
        registry.simulateUserResize(id: first, to: NSSize(width: 333, height: 444))
        t.expectEqual(preferences.defaultMemoWidth, 420, "끌어 맞춘 크기가 기본 크기를 덮어썼다")

        let second = registry.createMemo()
        t.expectEqual(registry.frame(of: second)?.size, NSSize(width: 333, height: 444), "켜져 있는데 맞춘 크기로 열리지 않았다")

        preferences.rememberLastMemoSize = false
        let third = registry.createMemo()
        t.expectEqual(registry.frame(of: third)?.size, NSSize(width: 420, height: 480), "꺼져 있는데 기본 크기로 열리지 않았다")

        // 접힌 창의 크기는 기록하지 않는다. 높이가 제목 줄뿐이기 때문이다.
        preferences.rememberLastMemoSize = true
        registry.toggleCollapsed(id: second)
        registry.simulateUserResize(id: second, to: NSSize(width: 500, height: 70))
        t.expectEqual(preferences.lastMemoSize?.width, 333, "접힌 창 크기가 기록됐다")
    }
}

runner.finish()
