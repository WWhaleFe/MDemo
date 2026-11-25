import Foundation
import MemoCore

/// 올리려는 메모 한 건의 내용. 불러오는 쪽이 채운다.
public struct NotionMemo: Sendable {
    public var document: MemoDocument
    /// 목록에 보이는 제목. 비어 있으면 "제목 없음".
    public var title: String
    public var attachmentsDirectory: URL

    public init(document: MemoDocument, title: String, attachmentsDirectory: URL) {
        self.document = document
        self.title = title
        self.attachmentsDirectory = attachmentsDirectory
    }
}

public struct NotionUploadResult: Sendable, Equatable {
    public struct Uploaded: Sendable, Equatable {
        public var id: MemoID
        public var url: String
    }
    public var uploaded: [Uploaded] = []
    /// 암호 메모 · 이 기기 전용 · 파기 장부에 있어 올리지 않은 개수.
    public var excluded = 0
    /// 사유와 함께 실패한 메모.
    public var failures: [MemoID: String] = [:]

    public init() {}

    public var summary: String {
        var parts: [String] = []
        if !uploaded.isEmpty { parts.append("노션에 올렸습니다 (\(uploaded.count)개)") }
        if excluded > 0 { parts.append("암호 메모 \(excluded)개는 올리지 않았습니다") }
        if !failures.isEmpty { parts.append("올리지 못한 메모 \(failures.count)개: " + failures.values.sorted().joined(separator: ", ")) }
        return parts.isEmpty ? "올릴 메모가 없습니다" : parts.joined(separator: "\n")
    }
}

/// 메모를 노션에 올린다.
///
/// **암호 메모는 절대 올리지 않는다.** 잠긴 메모(`meta.isLocked`) · 이 기기 전용 장부(local-only) · 파기 장부(destroyed)에 든 메모는
/// 메뉴에서 막는 것과 별개로 여기서도 노션 호출 전에 다시 거부한다. 장부를 읽지 못하면 안전하게 거부한다.
public struct NotionUploader: Sendable {
    private let api: any NotionAPI
    private let links: NotionLinkStore
    /// 데이터 폴더 (장부가 있는 곳).
    private let root: URL
    private let load: @Sendable (MemoID) async -> NotionMemo?

    public init(api: any NotionAPI, links: NotionLinkStore, root: URL, load: @escaping @Sendable (MemoID) async -> NotionMemo?) {
        self.api = api
        self.links = links
        self.root = root
        self.load = load
    }

    /// 이 메모가 노션에 올라가도 되는가. 메뉴 활성 여부 판단에도 쓴다.
    public static func isUploadAllowed(id: MemoID, isLocked: Bool, root: URL) -> Bool {
        if isLocked { return false }
        guard let blocked = try? ["local-only", "destroyed"].contains(where: { try MemoPrivacyLedger.read($0, root: root).contains(id.rawValue) })
        else { return false }
        return !blocked
    }

    /// 선택한 메모를 올린다. 올릴 수 없는 메모는 빼고 나머지를 올리며, 뺀 개수를 결과에 담는다.
    public func upload(ids: [MemoID], target: NotionTarget) async -> NotionUploadResult {
        var result = NotionUploadResult()
        var seen = Set<MemoID>()
        var titleProperty: String?
        for id in ids where seen.insert(id).inserted {
            // 노션을 부르기 전에 허용 여부부터 본다 (제목 속성 조회 포함).
            guard let memo = await load(id) else {
                result.failures[id] = "메모를 읽지 못했습니다"
                continue
            }
            guard Self.isUploadAllowed(id: id, isLocked: memo.document.meta.isLocked, root: root) else {
                result.excluded += 1
                continue
            }
            do {
                if target.type == .database, titleProperty == nil {
                    titleProperty = try await api.titlePropertyName(databaseID: target.id)
                }
                let page = try await uploadOne(memo, id: id, target: target, titleProperty: titleProperty)
                result.uploaded.append(.init(id: id, url: page.url))
            } catch {
                result.failures[id] = error.localizedDescription
                // 다시 로그인해야 하면 나머지도 같은 이유로 실패하므로 멈춘다.
                if error as? NotionError == .reauthRequired || error as? NotionError == .notSignedIn { break }
            }
        }
        return result
    }

    private func uploadOne(_ memo: NotionMemo, id: MemoID, target: NotionTarget, titleProperty: String?) async throws -> NotionPage {
        // 이중 차단: 이 함수 맨 앞에서도 다시 검사한다.
        guard Self.isUploadAllowed(id: id, isLocked: memo.document.meta.isLocked, root: root) else { throw NotionError.http(0, "암호 메모는 노션에 올릴 수 없습니다") }

        let title = memo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "제목 없음" : memo.title
        let property = target.type == .database ? (titleProperty ?? "title") : "title"
        let blocks = NotionBlocks.from(markdown: memo.document.body)

        // 이미지는 페이지를 만들기 전에 올린다. 실패한 이미지는 "[이미지]" 문단이 된다.
        var uploaded: [String: String] = [:]
        for path in Set(blocks.flatMap(\.imagePaths)) {
            let name = String(path.dropFirst("\(AttachmentImages.folderName)/".count))
            guard let data = try? Data(contentsOf: memo.attachmentsDirectory.appendingPathComponent(name)),
                  let fileID = try? await api.uploadImage(data: data, fileName: name) else { continue }
            uploaded[path] = fileID
        }

        var page: NotionPage?
        if let link = links.link(for: id), link.targetID == target.id {
            if let existing = try await api.existingPage(id: link.pageID) {
                try await api.updateTitle(pageID: existing.id, titleProperty: link.titleProperty, title: title)
                try await api.clearChildren(pageID: existing.id)
                page = existing
            }
        }
        if page == nil {
            page = try await api.createPage(target: target, titleProperty: property, title: title)
        }
        guard let page else { throw NotionError.invalidResponse }
        links.set(.init(pageID: page.id, targetID: target.id, titleProperty: property), for: id)
        try await api.append(pageID: page.id, blocks: blocks, uploadedImages: uploaded)
        return page
    }
}
