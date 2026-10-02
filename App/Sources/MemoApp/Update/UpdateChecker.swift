import AppKit
import Services
import UserNotifications

/// GitHub 릴리스에서 새 버전을 확인한다.
///
/// 이 앱에서 외부와 통신하는 유일한 코드다 (NFR-07 "업데이트 확인 제외").
/// 메모 내용은 보내지 않는다 — 공개 API에 최신 릴리스 정보를 묻기만 한다.
///
/// 새 버전을 찾아도 앱을 직접 바꿔 끼우지 않는다. 임시(ad-hoc) 서명 앱이라
/// 자동 교체는 위험하므로, 내려받은 zip을 Finder에서 보여 주고 설치는 사용자가 한다.
@MainActor
final class UpdateChecker: NSObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, downloadURL: URL?)
        case failed(String)
    }

    enum DownloadState: Equatable {
        case idle
        case downloading
        case done(URL)
        case failed(String)
    }

    static let repository = "WWhaleFe/MemoApp"
    private static let latestAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastNotifiedKey = "update.lastNotifiedVersion"

    private(set) var state: State = .idle
    private(set) var downloadState: DownloadState = .idle
    /// 상태가 바뀌면 부른다. 메뉴가 열려 있을 때 글자를 바로 고치기 위해 쓴다.
    var onChange: (() -> Void)?

    private let preferences: AppPreferences
    private var timer: Timer?

    init(preferences: AppPreferences) {
        self.preferences = preferences
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// 지금 앱의 버전. 번들 밖에서(`swift run`) 실행하면 버전이 없어 "dev"로 보인다.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    // MARK: - 자동 확인

    /// 켤 때 한 번, 그 뒤로 하루에 한 번 확인한다. 설정에서 끄면 멈춘다.
    func startAutomaticChecks() {
        timer?.invalidate()
        timer = nil
        guard preferences.autoCheckUpdate else { return }
        check(userInitiated: false)
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
    }

    // MARK: - 확인

    /// `userInitiated`가 false면 새 버전이 있을 때만 알림을 띄운다 (같은 버전은 한 번만).
    func check(userInitiated: Bool) {
        guard state != .checking else { return }
        setState(.checking)

        var request = URLRequest(url: Self.latestAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MDemo/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result = Self.parse(data: data, response: response, error: error)
            Task { @MainActor in self?.finishCheck(result, userInitiated: userInitiated) }
        }.resume()
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let browser_download_url: URL
        }
        let tag_name: String
        let assets: [Asset]
    }

    private nonisolated static func parse(data: Data?, response: URLResponse?, error: Error?) -> Result<Release, Error> {
        if let error { return .failure(error) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let data else {
            // 404는 아직 올린 릴리스가 없다는 뜻이다.
            return .failure(UpdateError(message: status == 404 ? "올라온 릴리스가 없습니다" : "응답 코드 \(status)"))
        }
        do {
            return .success(try JSONDecoder().decode(Release.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    private struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func finishCheck(_ result: Result<Release, Error>, userInitiated: Bool) {
        switch result {
        case .failure(let error):
            setState(.failed(error.localizedDescription))
        case .success(let release):
            let latest = Self.normalize(release.tag_name)
            guard Self.isNewer(latest, than: Self.currentVersion) else {
                setState(.upToDate)
                return
            }
            let zip = release.assets.first { $0.browser_download_url.pathExtension == "zip" }?.browser_download_url
            setState(.available(version: latest, downloadURL: zip))
            if !userInitiated {
                notifyOnce(version: latest)
            }
        }
    }

    /// "v0.9.1" → "0.9.1"
    static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// 점으로 나눈 숫자를 앞에서부터 비교한다. 자리 수가 다르면 없는 자리를 0으로 본다 (0.9 == 0.9.0).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - 내려받기

    /// 최신 zip을 다운로드 폴더에 받고 Finder에서 보여 준다. 설치는 사용자가 한다.
    func downloadLatest() {
        guard case .available(_, let url?) = state else {
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }
        guard downloadState != .downloading else { return }
        setDownloadState(.downloading)

        URLSession.shared.downloadTask(with: url) { [weak self] temporary, _, error in
            // 임시 파일은 이 블록이 끝나면 지워지므로 여기서 바로 옮긴다.
            let result: Result<URL, Error>
            if let temporary {
                result = Result { try Self.moveToDownloads(temporary, name: url.lastPathComponent) }
            } else {
                result = .failure(error ?? UpdateError(message: "내려받지 못했습니다"))
            }
            Task { @MainActor in
                switch result {
                case .success(let saved):
                    self?.setDownloadState(.done(saved))
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                case .failure(let error):
                    self?.setDownloadState(.failed(error.localizedDescription))
                }
            }
        }.resume()
    }

    private nonisolated static func moveToDownloads(_ temporary: URL, name: String) throws -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var destination = folder.appendingPathComponent(name)
        var suffix = 1
        // 같은 이름이 있으면 덮어쓰지 않고 -1, -2를 붙인다.
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base)-\(suffix).\(ext)")
            suffix += 1
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        return destination
    }

    // MARK: - 알림

    /// 같은 버전은 한 번만 알린다. 매일 확인할 때마다 같은 알림이 뜨면 성가시다.
    private func notifyOnce(version: String) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.lastNotifiedKey) != version else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "MDemo 새 버전 \(version)"
            content.body = "메뉴바의 MDemo 메뉴 → 업데이트에서 내려받을 수 있습니다."
            center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil))
        }
        defaults.set(version, forKey: Self.lastNotifiedKey)
    }

    // MARK: - 상태

    private func setState(_ newState: State) {
        state = newState
        onChange?()
    }

    private func setDownloadState(_ newState: DownloadState) {
        downloadState = newState
        onChange?()
    }

    /// 메뉴에 보일 한 줄 상태.
    var statusText: String {
        switch downloadState {
        case .downloading: return "내려받는 중…"
        case .done(let url): return "다운로드 폴더에 받았습니다: \(url.lastPathComponent)"
        case .failed(let message): return "내려받지 못했습니다: \(message)"
        case .idle: break
        }
        switch state {
        case .idle: return "아직 확인하지 않았습니다"
        case .checking: return "확인하는 중…"
        case .upToDate: return "최신 버전입니다"
        case .available(let version, _): return "새 버전 \(version)이 있습니다"
        case .failed(let message): return "확인하지 못했습니다: \(message)"
        }
    }

    var isUpdateAvailable: Bool {
        if case .available = state { return true }
        return false
    }
}

extension UpdateChecker: UNUserNotificationCenterDelegate {
    /// 알림을 누르면 릴리스 페이지를 연다.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in NSWorkspace.shared.open(Self.releasesPage) }
        completionHandler()
    }

    /// 앱이 앞에 있어도 알림을 보여 준다.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
