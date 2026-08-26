import Foundation

/// 기기별 창 상태를 보관한다 (SYNC-07).
///
/// 동기화 대상이 아니다. 창을 옮기거나 크기를 바꾸는 조작이
/// iCloud로 전파될 파일을 건드리지 않게 하려는 분리이기도 하다.
public final class DeviceStateStore: @unchecked Sendable {
    private let fileURL: URL
    private var states: [String: DeviceMemoState]
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.states = Self.read(from: fileURL)
    }

    /// 기본 위치: ~/Library/Application Support/MemoApp/device-state.json
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MemoApp/device-state.json")
    }

    private static func read(from url: URL) -> [String: DeviceMemoState] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: DeviceMemoState].self, from: data)
        else { return [:] }
        return decoded
    }

    public func state(for id: MemoID) -> DeviceMemoState? {
        lock.lock()
        defer { lock.unlock() }
        return states[id.rawValue]
    }

    public func setState(_ state: DeviceMemoState, for id: MemoID) {
        lock.lock()
        states[id.rawValue] = state
        lock.unlock()
    }

    public func removeState(for id: MemoID) {
        lock.lock()
        states.removeValue(forKey: id.rawValue)
        lock.unlock()
    }

    /// 디스크에 기록한다. 저장 중 종료돼도 파일이 깨지지 않도록 원자적으로 쓴다.
    public func flush() {
        lock.lock()
        let snapshot = states
        lock.unlock()

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            // 창 위치는 잃어도 메모는 잃지 않는다. 실패해도 앱 동작을 막지 않는다.
        }
    }
}
