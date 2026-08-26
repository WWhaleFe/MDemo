import AppKit
import EditorKit
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
        t.expect(collapsed <= 60, "제목 줄만 남아야 한다: \(collapsed)")

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

runner.finish()
