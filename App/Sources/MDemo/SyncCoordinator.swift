import Foundation
import MemoCore
import Observation
import Services
import StickyWindow

/// 동기화를 언제 돌릴지 정하고, 끝난 뒤 화면을 맞춘다 (SYNC-04, SYNC-05, SYNC-08).
///
/// 파일을 다루는 일은 오래 걸릴 수 있어 배경에서 하고,
/// 목록과 창을 손보는 일만 화면 쪽으로 가져온다.
@MainActor
@Observable
final class SyncCoordinator {
    enum Status: Equatable {
        case idle
        case syncing
        case done(SyncReport, at: Date)
        case failed(String)

        var menuText: String {
            switch self {
            case .idle: return "아직 동기화하지 않음"
            case .syncing: return "동기화 중…"
            case .done(let report, let date): return "\(Self.timeText(date)) · \(report.summary)"
            case .failed(let message): return "실패: \(message)"
            }
        }

        private static func timeText(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "a h:mm"
            return formatter.string(from: date)
        }
    }

    private(set) var status: Status = .idle
    var isAvailable: Bool { service != nil }

    @ObservationIgnored private let service: SyncService?
    @ObservationIgnored private let store: MemoStore
    @ObservationIgnored private let windowRegistry: WindowRegistry
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private var timer: Timer?
    /// 겹쳐 도는 것을 막는다. 파일을 양쪽에서 건드리면 결과가 어긋난다.
    @ObservationIgnored private var isRunning = false

    init(store: MemoStore, windowRegistry: WindowRegistry, preferences: AppPreferences) {
        self.store = store
        self.windowRegistry = windowRegistry
        self.preferences = preferences

        if let remoteRoot = SyncService.defaultRemoteRoot() {
            self.service = SyncService(
                localRoot: FileMemoRepository.defaultRootDirectory(),
                remoteRoot: remoteRoot,
                stateURL: SyncService.defaultStateURL()
            )
        } else {
            self.service = nil
        }
    }

    /// 앱을 켤 때 한 번 받아 오고, 그다음부터는 주기적으로 맞춘다 (SYNC-04, SYNC-05).
    func start() {
        guard isAvailable, preferences.autoSyncEnabled else { return }
        run(mode: .both)
        scheduleTimer()
    }

    func scheduleTimer() {
        timer?.invalidate()
        guard isAvailable, preferences.autoSyncEnabled else { return }

        let interval = max(60, preferences.autoSyncMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.run(mode: .both)
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 앱을 끄기 직전에는 기다리지 않고 바로 올린다.
    func syncBeforeTermination() {
        guard let service, preferences.autoSyncEnabled else { return }
        _ = try? service.sync(mode: .push)
    }

    func run(mode: SyncMode) {
        guard let service else {
            status = .failed(SyncError.iCloudUnavailable.localizedDescription)
            return
        }
        guard !isRunning else { return }

        isRunning = true
        status = .syncing

        Task.detached(priority: .utility) {
            let result: Result<SyncReport, Error>
            do {
                result = .success(try service.sync(mode: mode))
            } catch {
                result = .failure(error)
            }

            await MainActor.run { [weak self] in
                self?.finish(result)
            }
        }
    }

    private func finish(_ result: Result<SyncReport, Error>) {
        isRunning = false

        switch result {
        case .success(let report):
            status = .done(report, at: Date())
            guard !report.isEmpty else { return }

            // 파일이 바뀌었으니 목록을 다시 읽고, 열린 창도 맞춘다.
            store.reloadSummaries()
            store.reloadGroups()
            windowRegistry.reconcileOpenWindows(with: store)

        case .failure(let error):
            status = .failed(error.localizedDescription)
        }
    }
}
