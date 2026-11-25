import Foundation
import Observation

/// AirDrop으로 받은 사진을 받는 한 번의 세션 (시작 후 2분, 또는 그만 받을 때까지).
///
/// iPhone이 AirDrop으로 보낸 사진은 다운로드 폴더에 떨어지므로, 그 폴더를 지켜보다 새 이미지가
/// 다 써지면 `onReceive`로 넘긴다. 받은 원본은 지우지 않는다. 메모 창과 목록 창이 같이 쓴다.
@MainActor
@Observable
public final class AirDropReceiver {
    public var duration: TimeInterval { configuredDuration }
    public static let defaultDuration: TimeInterval = 120

    public private(set) var isActive = false
    public private(set) var remainingSeconds = 0
    public private(set) var receivedCount = 0

    /// 이미지 파일이 다 받아질 때마다. 받은 순서대로 한 장씩 온다.
    @ObservationIgnored public var onReceive: ((URL) -> Void)?
    /// 세션이 끝났을 때(시간 초과 또는 그만 받기). 받은 장수를 준다.
    @ObservationIgnored public var onFinish: ((Int) -> Void)?

    /// 상태(남은 시간, 받은 장수, 켜짐)가 바뀔 때마다. AppKit 화면이 따라 그릴 때 쓴다.
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let configuredDuration: TimeInterval
    @ObservationIgnored private let settleInterval: TimeInterval
    @ObservationIgnored private var watcher: DownloadsWatcher?
    @ObservationIgnored private var countdown: Timer?
    @ObservationIgnored private var deadline = Date()

    public init(directory: URL? = nil, duration: TimeInterval = AirDropReceiver.defaultDuration, settleInterval: TimeInterval = 0.5) {
        self.directory = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        self.configuredDuration = duration
        self.settleInterval = settleInterval
    }

    public func start() {
        guard !isActive else { return }
        isActive = true
        receivedCount = 0
        deadline = Date().addingTimeInterval(configuredDuration)
        remainingSeconds = Int(configuredDuration.rounded(.up))

        let watcher = DownloadsWatcher(directory: directory, settleInterval: settleInterval) { [weak self] url in
            guard let self, self.isActive else { return }
            self.receivedCount += 1
            self.onReceive?(url)
            self.onChange?()
        }
        watcher.start()
        self.watcher = watcher

        onChange?()
        countdown = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// 지켜보기를 멈추고 자원을 모두 푼다. 이미 멈춰 있으면 아무 일도 없다.
    public func stop() {
        guard isActive else { return }
        isActive = false
        watcher?.stop()
        watcher = nil
        countdown?.invalidate()
        countdown = nil
        remainingSeconds = 0
        onChange?()
        onFinish?(receivedCount)
    }

    private func tick() {
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            stop()
        } else {
            let seconds = Int(left.rounded(.up))
            if seconds != remainingSeconds {
                remainingSeconds = seconds
                onChange?()
            }
        }
    }
}
