import AppKit
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
        case signingIn
        case done(SyncReport, at: Date)
        case failed(String)

        var menuText: String {
            switch self {
            case .idle: return "아직 동기화하지 않음"
            case .syncing: return "동기화 중…"
            case .signingIn: return "구글 로그인 중… 브라우저에서 계속해 주세요"
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

    /// 동기화는 구글 드라이브 하나뿐이다. Windows판도 같은 드라이브로 맞추기 위해 iCloud 동기화는 없앴다.
    /// 거울 폴더를 거쳐 드라이브와 맞춘다. 로그인하지 않았으면 nil.
    private typealias Backend = DriveMirrorSync

    private(set) var status: Status = .idle
    var isAvailable: Bool { backend != nil }
    /// 구글에 로그인되어 있으면 그 이메일.
    private(set) var googleEmail: String?
    /// 구글 로그인 설정(GoogleOAuth.plist)이 있고 시험 모드가 아닌가.
    let isGoogleConfigured: Bool

    @ObservationIgnored private var backend: Backend?
    @ObservationIgnored private let googleConfig: GoogleOAuthConfig?
    @ObservationIgnored private let tokenStore: any GoogleTokenStore
    @ObservationIgnored private var session: GoogleSession?
    @ObservationIgnored private let store: MemoStore
    @ObservationIgnored private let windowRegistry: WindowRegistry
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private var timer: Timer?
    /// 겹쳐 도는 것을 막는다. 파일을 양쪽에서 건드리면 결과가 어긋난다.
    @ObservationIgnored private var isRunning = false

    /// 개발용: `--data-dir=<폴더>`와 `--google-sync-test`를 함께 주면 시험 폴더로 실제 구글 동기화를 시험한다.
    /// 거울 폴더 · 상태 파일은 `<폴더>-google`에, 토큰은 실제와 다른 키체인 항목에 둔다.
    /// 실제 데이터 폴더와 실제 로그인은 건드리지 않는다.
    static let googleTestRoot: URL? = {
        guard let dataRoot = AppContainer.dataDirectoryOverride,
              CommandLine.arguments.contains("--google-sync-test") else { return nil }
        return dataRoot.deletingLastPathComponent()
            .appendingPathComponent(dataRoot.lastPathComponent + "-google", isDirectory: true)
    }()
    private static let testTokenService = "com.wwhalefe.MDemo.google.devtest"

    init(store: MemoStore, windowRegistry: WindowRegistry, preferences: AppPreferences) {
        self.store = store
        self.windowRegistry = windowRegistry
        self.preferences = preferences

        let isTestMode = AppContainer.dataDirectoryOverride != nil
        let googleTest = Self.googleTestRoot != nil
        self.tokenStore = googleTest ? KeychainGoogleTokenStore(serviceName: Self.testTokenService) : KeychainGoogleTokenStore()
        self.googleConfig = (isTestMode && !googleTest) ? nil : GoogleOAuthConfig.load()
        self.isGoogleConfigured = googleConfig != nil

        // 시험 모드(--data-dir)는 --google-sync-test를 함께 줄 때만 구글을 쓴다.
        if let config = googleConfig, let credentials = (try? tokenStore.load()) ?? nil {
            let session = GoogleSession(config: config, store: tokenStore, transport: GoogleHTTP())
            self.session = session
            self.googleEmail = credentials.email
            self.backend = Self.makeGoogleSync(session: session)
        } else {
            self.backend = nil
        }
    }

    private static func makeGoogleSync(session: GoogleSession) -> DriveMirrorSync {
        let paths = googlePaths
        return DriveMirrorSync(
            localRoot: AppContainer.dataDirectoryOverride ?? FileMemoRepository.defaultRootDirectory(),
            mirrorRoot: paths.folder.appendingPathComponent(AppStorageName.folder, isDirectory: true),
            driveStateURL: paths.folder.appendingPathComponent("drive-state.json"),
            engineStateURL: paths.engineState,
            api: GoogleDriveClient(tokens: session),
            log: { NSLog("MDemo 드라이브: %@", $0) }
        )
    }

    /// 거울 폴더와 엔진 상태 파일 자리. 시험 실행이면 시험 폴더 옆으로 뺀다.
    private static var googlePaths: (folder: URL, engineState: URL) {
        if let root = googleTestRoot {
            return (root.appendingPathComponent("GoogleDrive", isDirectory: true),
                    root.appendingPathComponent("sync-state-google.json"))
        }
        return (DriveMirrorSync.defaultGoogleFolder(), DriveMirrorSync.defaultEngineStateURL())
    }

    /// 구글에 로그인해 동기화할 수 있는가.
    var isGoogleBackend: Bool { backend != nil }

    // MARK: - 구글 로그인 · 로그아웃

    /// 브라우저로 로그인한 뒤 확인 없이 곧바로 첫 동기화(합치기)를 돈다.
    func signInWithGoogle() {
        guard let config = googleConfig, !isRunning else { return }
        isRunning = true
        status = .signingIn
        let tokenStore = tokenStore
        Task { [weak self] in
            let session = GoogleSession(config: config, store: tokenStore, transport: GoogleHTTP())
            do {
                let email = try await session.signIn(openBrowser: { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                })
                guard let self else { return }
                self.session = session
                self.googleEmail = email
                self.backend = Self.makeGoogleSync(session: session)
                self.isRunning = false
                self.run(mode: .both)
                self.scheduleTimer()
            } catch {
                self?.isRunning = false
                self?.status = .failed(error.localizedDescription)
            }
        }
    }

    /// 토큰 폐기를 시도하고 키체인 · 거울 폴더 · 상태 파일을 지운다. 로그아웃하면 동기화하지 않는다.
    /// 데이터 폴더의 메모는 그대로다.
    func signOutGoogle() {
        guard backend != nil, let session, !isRunning else {
            if isRunning { status = .failed("동기화 중입니다. 끝난 뒤 다시 눌러 주세요") }
            return
        }
        isRunning = true
        stopTimer()
        Task { [weak self] in
            try? await session.signOut()
            let paths = Self.googlePaths
            DriveMirrorSync.resetLocalState(googleFolder: paths.folder, engineStateURL: paths.engineState)
            guard let self else { return }
            self.session = nil
            self.googleEmail = nil
            self.backend = nil
            self.status = .idle
            self.isRunning = false
            self.scheduleTimer()
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
        guard let backend, preferences.autoSyncEnabled else { return }
        // 끄기 직전이라 잠깐만 기다린다. 못 끝낸 것은 다음 실행에서 이어 한다.
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await backend.sync(mode: .push)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
    }

    func run(mode: SyncMode) {
        guard let backend else {
            status = .failed("구글 계정으로 로그인하면 동기화합니다")
            return
        }
        // 개인정보 정리 등 다른 일이 도는 중이면 버리지 않고 끝난 뒤 돈다.
        // 앱을 켤 때 정리와 첫 동기화가 겹쳐 첫 동기화가 빠지던 문제.
        guard !isRunning else {
            if let pending = pendingRun, pending != mode { pendingRun = .both } else { pendingRun = mode }
            return
        }

        isRunning = true
        status = .syncing

        Task.detached(priority: .utility) {
            let result: Result<SyncReport, Error>
            do {
                result = .success(try await backend.sync(mode: mode))
            } catch {
                result = .failure(error)
            }

            await MainActor.run { [weak self] in
                self?.finish(result)
            }
        }
    }

    private var privacyPending = false
    @ObservationIgnored private var pendingRun: SyncMode?
    func enforcePrivacy() {
        guard !isRunning else { privacyPending = true; return }
        isRunning = true
        let backend = backend
        let lockedCount = store.summaries.filter { $0.meta.isLocked }.count
        let localRoot = AppContainer.dataDirectoryOverride ?? FileMemoRepository.defaultRootDirectory()
        Task.detached(priority: .utility) { [weak self] in
            let result: Result<SyncReport, Error>
            do {
                var removedLocal = 0
                for raw in try MemoPrivacyLedger.read("destroyed", root: localRoot) {
                    let id = MemoID(rawValue: raw)
                    let exists = ["memos", "trash"].contains { FileManager.default.fileExists(atPath: localRoot.appendingPathComponent($0).appendingPathComponent(raw).path) }
                    try DeviceMemoKeychain().delete(id: id)
                    try SecureMemoDeletion.removeCopies(id: id, root: localRoot)
                    if exists { removedLocal += 1 }
                }
                var report: SyncReport
                if let backend { report = try await backend.enforcePrivacy() } else { report = SyncReport() }
                report.deletions += removedLocal
                if backend == nil { report.lockedLocal = lockedCount }
                result = .success(report)
            } catch { result = .failure(error) }
            await MainActor.run { self?.finish(result) }
        }
    }

    private func finish(_ result: Result<SyncReport, Error>) {
        isRunning = false
        defer {
            if privacyPending {
                privacyPending = false
                enforcePrivacy()
            } else if let mode = pendingRun {
                pendingRun = nil
                run(mode: mode)
            }
        }

        switch result {
        case .success(let report):
            status = .done(report, at: Date())
            guard !report.isEmpty else { return }

            // 파일이 바뀌었으니 목록을 다시 읽고, 열린 창도 맞춘다.
            store.reloadSummaries()
            store.reloadGroups()
            store.reloadTrash()
            windowRegistry.reconcileOpenWindows(with: store)

        case .failure(let error):
            status = .failed(error.localizedDescription)
        }
    }
}
