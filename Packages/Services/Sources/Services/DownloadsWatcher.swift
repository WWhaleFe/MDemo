import Darwin
import Foundation

/// 폴더에 새로 생긴 이미지가 "다 써졌는지" 판단하는 논리 (AirDrop 받기).
///
/// 시간을 밖에서 받으므로 임시 폴더와 가짜 시계로 시험할 수 있다.
/// - 시작할 때 이미 있던 파일은 무시한다.
/// - 크기가 `settleInterval` 동안 그대로이고 0이 아니면 다 써진 것으로 본다.
/// - 숨김 파일과 이미지가 아닌 파일은 무시한다. 원본은 지우지 않는다.
@MainActor
public final class DownloadsScanner {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif"]

    private let directory: URL
    private let settleInterval: TimeInterval
    private var known: Set<String> = []
    private var pending: [String: (size: Int, since: Date)] = [:]

    public init(directory: URL, settleInterval: TimeInterval = 0.5) {
        self.directory = directory
        self.settleInterval = settleInterval
    }

    /// 지금 있는 파일을 "이미 있던 것"으로 기록한다.
    public func begin() {
        known = Set(listing().map(\.lastPathComponent))
        pending = [:]
    }

    /// 아직 다 써지기를 기다리는 파일이 있는가. 있으면 크기를 계속 살펴야 한다.
    public var hasPending: Bool { !pending.isEmpty }

    /// 다 써진 새 이미지들. AirDrop 표시가 있는 것을 먼저, 그다음 수정 시각 순이다.
    public func scan(now: Date = Date()) -> [URL] {
        var ready: [(url: URL, isAirDrop: Bool, modified: Date)] = []
        var seen = Set<String>()

        for url in listing() {
            let name = url.lastPathComponent
            guard !known.contains(name), Self.imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            seen.insert(name)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0

            var entry = pending[name] ?? (size: size, since: now)
            if entry.size != size { entry = (size: size, since: now) }
            pending[name] = entry

            if size > 0, now.timeIntervalSince(entry.since) >= settleInterval {
                ready.append((url, Self.isAirDropped(url), values?.contentModificationDate ?? now))
            }
        }
        // 지켜보던 파일이 사라졌으면(받다가 취소) 더는 기다리지 않는다.
        for name in pending.keys where !seen.contains(name) { pending[name] = nil }
        for item in ready {
            known.insert(item.url.lastPathComponent)
            pending[item.url.lastPathComponent] = nil
        }
        return ready.sorted {
            if $0.isAirDrop != $1.isAirDrop { return $0.isAirDrop }
            return $0.modified < $1.modified
        }.map(\.url)
    }

    private func listing() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// 격리 속성(`com.apple.quarantine`)의 에이전트 이름이 AirDrop(sharingd)인가. 없으면 false.
    public nonisolated static func isAirDropped(_ url: URL) -> Bool {
        let name = "com.apple.quarantine"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, name, &buffer, length, 0, 0) == length else { return false }
        let value = String(decoding: buffer, as: UTF8.self).lowercased()
        return value.contains("sharingd") || value.contains("airdrop")
    }
}

/// 폴더를 지켜보다 새 이미지가 다 써지면 알려 준다.
///
/// 폴더에 파일이 생기면 `DispatchSource`가 깨우고, 다 써지기를 기다리는 파일이 있는 동안만
/// 짧은 간격으로 크기를 살핀다. `stop()`은 감시 자원(파일 기술자, 타이머)을 모두 해제한다.
@MainActor
public final class DownloadsWatcher {
    private let scanner: DownloadsScanner
    private let directory: URL
    private let pollInterval: TimeInterval
    private let onReady: (URL) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?

    public private(set) var isRunning = false

    public init(directory: URL, settleInterval: TimeInterval = 0.5, pollInterval: TimeInterval = 0.25, onReady: @escaping (URL) -> Void) {
        self.directory = directory
        self.scanner = DownloadsScanner(directory: directory, settleInterval: settleInterval)
        self.pollInterval = pollInterval
        self.onReady = onReady
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        scanner.begin()

        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .link], queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.check() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        // 폴더를 열지 못해도(권한 등) 느린 점검으로 물러선다.
        if source == nil { schedulePolling() }
    }

    public func stop() {
        isRunning = false
        source?.cancel()
        source = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 지금 한 번 살펴본다. 시험과 감시기가 함께 쓴다.
    public func check() {
        guard isRunning else { return }
        for url in scanner.scan() { onReady(url) }
        if scanner.hasPending || source == nil {
            schedulePolling()
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func schedulePolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: source == nil ? 1 : pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }
}
