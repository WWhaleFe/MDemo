import AppKit
import Foundation
import MemoCore
import Observation
import Services
import StickyWindow
import SwiftUI

/// 노션 로그인 · 올릴 곳 · 올리기를 묶는다. 메뉴바, 목록 우클릭, 메모 창 우클릭이 모두 여기로 온다.
///
/// 메모 내용은 앱이 노션과 직접 주고받는다. 중계 서버는 로그인 코드 교환만 한다.
/// 암호 메모는 `NotionUploader`가 막는다. 여기서는 메뉴를 흐리게 하는 판단만 한다.
@MainActor
@Observable
final class NotionCoordinator {
    /// 노션 로그인 설정(NotionOAuth.plist)이 있고 시험 모드가 아닌가.
    let isConfigured: Bool
    private(set) var workspaceName: String?
    private(set) var target: NotionTarget?
    private(set) var isSigningIn = false
    private(set) var isUploading = false

    @ObservationIgnored private let config: NotionOAuthConfig?
    @ObservationIgnored private let tokenStore: any NotionTokenStore
    @ObservationIgnored private let targetStore: NotionTargetStore
    @ObservationIgnored private let links: NotionLinkStore

    /// 개발용: `--data-dir=<폴더>`와 `--notion-test`를 함께 주면 시험 폴더의 메모로 실제 노션 올리기를 시험한다.
    /// 토큰 · 올릴 곳 · 올린 기록은 실제와 다른 자리에 둔다(키체인 항목 · 설정 키 · `<폴더>-notion-links.json`).
    static let isNotionTest = AppContainer.dataDirectoryOverride != nil && CommandLine.arguments.contains("--notion-test")
    @ObservationIgnored private var session: NotionSession?
    @ObservationIgnored private let store: MemoStore
    @ObservationIgnored private let windowRegistry: WindowRegistry
    @ObservationIgnored private let dataRoot: URL
    @ObservationIgnored private var pickerWindow: NSWindow?

    var isSignedIn: Bool { workspaceName != nil }

    init(store: MemoStore, windowRegistry: WindowRegistry) {
        self.store = store
        self.windowRegistry = windowRegistry
        let isTestMode = AppContainer.dataDirectoryOverride != nil
        self.dataRoot = AppContainer.dataDirectoryOverride ?? FileMemoRepository.defaultRootDirectory()
        if Self.isNotionTest, let root = AppContainer.dataDirectoryOverride {
            self.tokenStore = KeychainNotionTokenStore(serviceName: KeychainNotionTokenStore.service + ".devtest")
            self.targetStore = NotionTargetStore(key: NotionTargetStore.key + ".devtest")
            self.links = NotionLinkStore(fileURL: root.deletingLastPathComponent()
                .appendingPathComponent(root.lastPathComponent + "-notion-links.json"))
        } else {
            self.tokenStore = KeychainNotionTokenStore()
            self.targetStore = NotionTargetStore()
            self.links = NotionLinkStore(fileURL: NotionLinkStore.defaultFileURL())
        }
        self.config = (isTestMode && !Self.isNotionTest) ? nil : NotionOAuthConfig.load()
        self.isConfigured = config != nil
        if let config, let credentials = (try? tokenStore.load()) ?? nil {
            self.session = NotionSession(config: config, store: tokenStore, transport: NotionHTTP())
            self.workspaceName = credentials.workspaceName
            self.target = targetStore.target
        }
    }

    // MARK: - 로그인 · 로그아웃

    func signIn() {
        guard let config, !isSigningIn else { return }
        isSigningIn = true
        let tokenStore = tokenStore
        Task { [weak self] in
            let session = NotionSession(config: config, store: tokenStore, transport: NotionHTTP())
            do {
                let credentials = try await session.signIn(openBrowser: { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                })
                guard let self else { return }
                // 다른 워크스페이스로 로그인하면 이전 올릴 곳과 연결 기록은 쓸 수 없다.
                if self.workspaceName != nil, self.workspaceName != credentials.workspaceName {
                    self.resetTargetAndLinks()
                }
                self.session = session
                self.workspaceName = credentials.workspaceName
                self.target = self.targetStore.target
                self.isSigningIn = false
            } catch {
                self?.isSigningIn = false
                Self.alert(title: "노션에 로그인하지 못했습니다", text: error.localizedDescription)
            }
        }
    }

    /// 키체인 항목 · 올릴 곳 설정 · 페이지 연결 기록을 지운다.
    func signOut() {
        let session = session
        Task { [weak self] in
            do { try await session?.signOut() } catch { NSLog("MDemo 노션: 로그아웃 중 키체인 오류, %@", error.localizedDescription) }
            // 세션이 없어도(앱을 켠 뒤 상태가 어긋난 경우) 키체인은 확실히 지운다.
            try? self?.tokenStore.delete()
            guard let self else { return }
            self.resetTargetAndLinks()
            self.session = nil
            self.workspaceName = nil
        }
    }

    private func resetTargetAndLinks() {
        targetStore.target = nil
        links.removeAll()
        target = nil
    }

    // MARK: - 올릴 곳

    func chooseTarget() {
        guard let session else { return }
        if let pickerWindow {
            pickerWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let client = NotionClient(tokens: session)
        let view = NotionTargetPickerView(
            current: target,
            search: { query in try await client.search(query: query) },
            onChoose: { [weak self] chosen in
                self?.targetStore.target = chosen
                self?.target = chosen
                self?.closePicker()
            },
            onCancel: { [weak self] in self?.closePicker() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "노션에 올릴 곳 고르기"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        pickerWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closePicker() {
        pickerWindow?.close()
        pickerWindow = nil
    }

    // MARK: - 올리기

    /// 메뉴를 흐리게 할지 정하는 판단. 올리는 쪽(`NotionUploader`)이 한 번 더 막는다.
    func canUpload(_ id: MemoID) -> Bool {
        guard let summary = store.summaries.first(where: { $0.id == id }) else { return false }
        return NotionUploader.isUploadAllowed(id: id, isLocked: summary.meta.isLocked, root: dataRoot)
    }

    func upload(_ ids: [MemoID]) {
        guard !ids.isEmpty, !isUploading else { return }
        guard isConfigured else {
            Self.alert(title: "노션 로그인 설정이 없습니다", text: "이 빌드에는 NotionOAuth.plist가 들어 있지 않습니다. README의 \"노션에 올리기\" 개발자용 설정을 확인해 주세요.")
            return
        }
        guard let session else {
            if Self.confirm(title: "노션에 로그인해 주세요", text: "메모를 올리려면 먼저 노션 계정으로 로그인해야 합니다.", button: "노션 계정으로 로그인…") { signIn() }
            return
        }
        guard let target else {
            if Self.confirm(title: "올릴 곳을 먼저 골라 주세요", text: "메모를 올릴 노션 페이지 또는 데이터베이스를 정해야 합니다.", button: "올릴 곳 고르기…") { chooseTarget() }
            return
        }

        // 열려 있는 창의 편집 중인 내용을 저장소에 반영한 뒤 읽는다.
        for id in ids { windowRegistry.flushBody(id: id) }
        isUploading = true
        let uploader = NotionUploader(
            api: NotionClient(tokens: session),
            links: links,
            root: dataRoot,
            load: { [store] id in
                await MainActor.run {
                    guard let document = store.loadDocument(id: id) else { return nil }
                    let title = store.summaries.first { $0.id == id }?.title ?? ""
                    return NotionMemo(document: document, title: title, attachmentsDirectory: store.attachmentsDirectory(for: id))
                }
            }
        )
        Task { [weak self] in
            let result = await uploader.upload(ids: ids, target: target)
            self?.isUploading = false
            Self.report(result)
        }
    }

    private static func report(_ result: NotionUploadResult) {
        let alert = NSAlert()
        alert.messageText = result.uploaded.isEmpty ? "노션에 올리지 못했습니다" : "노션에 올렸습니다"
        alert.informativeText = result.summary
        alert.alertStyle = result.failures.isEmpty ? .informational : .warning
        let url = result.uploaded.compactMap { URL(string: $0.url) }.first
        if url != nil { alert.addButton(withTitle: "노션에서 열기") }
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let url { NSWorkspace.shared.open(url) }
    }

    private static func alert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func confirm(title: String, text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
