import Foundation
import MemoCore
import Observation
import Services

/// 목록 창에서 메모를 열지 않고 AirDrop 사진을 받는 한 번의 세션.
///
/// 받은 사진은 그 메모의 첨부 폴더에 저장하고(큰 이미지는 줄여서), 본문 맨 위 또는 맨 아래에
/// 이미지 줄로 더해 저장한다. 메모 창이 이미 떠 있으면 창 쪽과 어긋나지 않도록
/// `withExternalBodyEdit`로 창의 편집 내용을 먼저 저장하고 고친 뒤 다시 읽게 한다.
@MainActor
@Observable
public final class ListAirDropSession {
    public let memoID: MemoID
    public let title: String
    public let position: BodyImageInsertion.Position
    public let receiver: AirDropReceiver

    @ObservationIgnored private let store: MemoStore
    @ObservationIgnored private let windowActions: MemoWindowActions
    /// 맨 위에 넣을 때, 받은 순서가 뒤집히지 않도록 이미 넣은 줄 수를 센다.
    @ObservationIgnored private var insertedCount = 0
    @ObservationIgnored public var onFinish: (() -> Void)?

    public init(
        memoID: MemoID,
        title: String,
        position: BodyImageInsertion.Position,
        store: MemoStore,
        windowActions: MemoWindowActions,
        receiver: AirDropReceiver = AirDropReceiver()
    ) {
        self.memoID = memoID
        self.title = title
        self.position = position
        self.store = store
        self.windowActions = windowActions
        self.receiver = receiver
        receiver.onReceive = { [weak self] url in self?.handleReceived(url) }
        receiver.onFinish = { [weak self] _ in self?.onFinish?() }
    }

    public var isActive: Bool { receiver.isActive }
    public var receivedCount: Int { receiver.receivedCount }
    public var remainingSeconds: Int { receiver.remainingSeconds }

    /// 안내 띠에 쓰는 자리 이름.
    public var positionText: String { position == .top ? "맨 위" : "맨 아래" }

    public func start() { receiver.start() }
    public func stop() { receiver.stop() }

    /// 받은 사진 한 장을 저장하고 본문에 줄을 더한다. 저장에 실패하면 그 장은 건너뛴다.
    func handleReceived(_ url: URL) {
        guard let saved = try? AttachmentImages.save(
            imageFileAt: url, into: store.attachmentsDirectory(for: memoID)
        ) else { return }
        let alt = url.deletingPathExtension().lastPathComponent
            .filter { $0 != "[" && $0 != "]" && !$0.isNewline }
        let line = "![\(alt)](\(saved.relativePath))"
        let position = position
        let skipped = insertedCount
        windowActions.withExternalBodyEdit(memoID) { [store, memoID] in
            guard let document = store.loadDocument(id: memoID) else { return }
            let body = BodyImageInsertion.inserting([line], into: document.body, at: position, skippingInserted: skipped)
            store.saveBody(id: memoID, body: body)
        }
        insertedCount += 1
    }
}

extension MemoListModel {
    /// 그 메모에 AirDrop 사진 받기를 시작한다. 이미 받는 중이면 먼저 멈춘다.
    public func startAirDrop(for id: MemoID, position: BodyImageInsertion.Position) {
        airDrop?.stop()
        let title = store.summaries.first { $0.id == id }?.title ?? "메모"
        let session = ListAirDropSession(
            memoID: id, title: title.isEmpty ? "제목 없음" : title, position: position,
            store: store, windowActions: windowActions
        )
        session.onFinish = { [weak self, weak session] in
            // 끝나면 띠를 걷는다. 그 사이 다른 세션이 시작됐으면 건드리지 않는다.
            guard let self, self.airDrop === session else { return }
            self.airDrop = nil
            self.refresh()
        }
        airDrop = session
        session.start()
    }

    public func stopAirDrop() {
        airDrop?.stop()
        airDrop = nil
    }
}
