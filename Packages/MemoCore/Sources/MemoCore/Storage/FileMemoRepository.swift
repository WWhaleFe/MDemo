import Foundation

/// 마크다운 파일이 원본인 저장소 (DAT-01).
///
/// 폴더 구조 (설계서 §3-1):
/// ```
/// <데이터 폴더>/memos/<ULID>/memo.md
/// <데이터 폴더>/memos/<ULID>/attachments/
/// <데이터 폴더>/trash/<ULID>/
/// ```
/// 메모 하나가 폴더 하나라서 휴지통 이동·복원·첨부 동반 삭제가 폴더 이동 한 번으로 끝난다.
public struct FileMemoRepository: MemoRepository {
    public let rootDirectory: URL

    private static let memoFileName = "memo.md"
    private static let memosFolder = "memos"
    private static let trashFolder = "trash"
    /// 목록 미리보기를 만들 때 파일 앞부분만 읽는 크기. 본문 전체를 메모리에 올리지 않기 위한 값이다.
    private static let previewReadLimit = 8 * 1024
    private static let previewCharacterLimit = 200

    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        try FileManager.default.createDirectory(
            at: rootDirectory.appendingPathComponent(Self.memosFolder),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootDirectory.appendingPathComponent(Self.trashFolder),
            withIntermediateDirectories: true
        )
    }

    /// 기본 데이터 폴더: ~/Library/Application Support/MDemo/Data
    public static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(AppStorageName.folder)/Data", isDirectory: true)
    }

    // MARK: - 경로

    private func memoDirectory(for id: MemoID) -> URL {
        rootDirectory
            .appendingPathComponent(Self.memosFolder, isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
    }

    private func memoFileURL(for id: MemoID) -> URL {
        memoDirectory(for: id).appendingPathComponent(Self.memoFileName)
    }

    public func attachmentsDirectory(for id: MemoID) -> URL {
        memoDirectory(for: id).appendingPathComponent("attachments", isDirectory: true)
    }

    // MARK: - 읽기

    public func loadSummaries() throws -> [MemoSummary] {
        let memosURL = rootDirectory.appendingPathComponent(Self.memosFolder, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: memosURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var summaries: [MemoSummary] = []
        for entry in entries {
            let id = MemoID(rawValue: entry.lastPathComponent)
            guard id.isValid else { continue }
            // 파일 하나가 깨져도 나머지 메모는 열려야 한다.
            guard let summary = try? loadSummary(id: id) else { continue }
            summaries.append(summary)
        }
        return summaries.sorted { $0.meta.modified > $1.meta.modified }
    }

    /// 파일 앞부분만 읽어 요약을 만든다. 긴 본문을 통째로 메모리에 올리지 않는다.
    private func loadSummary(id: MemoID) throws -> MemoSummary {
        let url = memoFileURL(for: id)
        let head = try readHead(of: url, limit: Self.previewReadLimit)
        let document = try FrontmatterCodec.decode(fileContents: head)
        return MemoSummary(meta: document.meta, preview: String(document.body.prefix(Self.previewCharacterLimit)))
    }

    private func readHead(of url: URL, limit: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit) ?? Data()

        guard var text = String(data: data, encoding: .utf8) else {
            // 잘린 지점이 UTF-8 문자 중간이면 뒤에서 몇 바이트를 덜어내고 다시 시도한다.
            for drop in 1...3 where data.count > drop {
                if let recovered = String(data: data.dropLast(drop), encoding: .utf8) {
                    return recovered
                }
            }
            throw FrontmatterError.missingOpeningDelimiter
        }
        // 앞부분만 읽어 닫는 구분자가 잘렸다면 전체를 읽는다 (프론트매터가 매우 긴 예외적 경우).
        if countDelimiters(in: text) < 2 {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        return text
    }

    private func countDelimiters(in text: String) -> Int {
        text.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) == "---" }
            .count
    }

    public func load(id: MemoID) throws -> MemoDocument {
        let text = try String(contentsOf: memoFileURL(for: id), encoding: .utf8)
        return try FrontmatterCodec.decode(fileContents: text)
    }

    // MARK: - 쓰기

    /// 임시 파일에 쓰고 교체하는 방식으로 저장한다.
    /// 저장 도중 앱이 강제 종료돼도 기존 파일이 손상되지 않는다 (DAT-08).
    public func save(_ document: MemoDocument) throws {
        let directory = memoDirectory(for: document.meta.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let text = FrontmatterCodec.encode(document)
        guard let data = text.data(using: .utf8) else { return }
        try data.write(to: memoFileURL(for: document.meta.id), options: .atomic)
    }

    // MARK: - 삭제

    public func moveToTrash(id: MemoID) throws {
        let source = memoDirectory(for: id)
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        let destination = trashDirectory(for: id)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // 첨부 폴더까지 통째로 따라간다 (TRS-05).
        try FileManager.default.moveItem(at: source, to: destination)
        // 버린 시각은 폴더의 수정 시각으로 기록한다 (TRS-03).
        // 폴더를 옮기기만 하면 수정 시각은 마지막으로 고친 때 그대로라,
        // 오래 묵은 메모를 버리면 다음 자동 비우기에서 곧바로 지워졌다.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
    }

    private func trashDirectory(for id: MemoID) -> URL {
        rootDirectory
            .appendingPathComponent(Self.trashFolder, isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// 휴지통 목록. 화면에는 "언제 버렸는지"가 필요한데, 그 시각은 폴더가 옮겨진 시각으로 안다.
    public func loadTrashSummaries() throws -> [MemoSummary] {
        let trashURL = rootDirectory.appendingPathComponent(Self.trashFolder, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var summaries: [MemoSummary] = []
        for entry in entries {
            let id = MemoID(rawValue: entry.lastPathComponent)
            guard id.isValid else { continue }
            let url = entry.appendingPathComponent(Self.memoFileName)
            guard let head = try? readHead(of: url, limit: Self.previewReadLimit),
                  let document = try? FrontmatterCodec.decode(fileContents: head)
            else { continue }

            var summary = MemoSummary(
                meta: document.meta,
                preview: String(document.body.prefix(Self.previewCharacterLimit))
            )
            summary.deletedAt = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            summaries.append(summary)
        }
        return summaries.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    public func restoreFromTrash(id: MemoID) throws {
        let source = trashDirectory(for: id)
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        let destination = memoDirectory(for: id)
        if FileManager.default.fileExists(atPath: destination.path) {
            // 같은 ID가 이미 있으면 되돌리지 않는다. 덮어써서 잃는 것보다 남기는 편이 낫다.
            return
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// 폴더째 지우므로 첨부 이미지도 함께 사라진다 (TRS-05).
    public func permanentlyDelete(id: MemoID) throws {
        let target = trashDirectory(for: id)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }

    public func emptyTrash(deletedBefore date: Date?) throws {
        let trashURL = rootDirectory.appendingPathComponent(Self.trashFolder, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries {
            guard MemoID(rawValue: entry.lastPathComponent).isValid else { continue }
            if let date {
                let deletedAt = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date()
                guard deletedAt < date else { continue }
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - 그룹 (LST-02)

    private var groupsFileURL: URL {
        rootDirectory.appendingPathComponent("groups.json")
    }

    public func loadGroups() throws -> [String] {
        guard let data = try? Data(contentsOf: groupsFileURL),
              let groups = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return groups
    }

    public func saveGroups(_ groups: [String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(groups).write(to: groupsFileURL, options: .atomic)
    }

    // MARK: - 본문 검색 (SRC-01)

    /// 파일을 하나씩 열어 보고 곧바로 버린다.
    ///
    /// 본문을 메모리에 쌓아 두면 메모가 많아질수록 상주 메모리가 늘어난다.
    /// 검색은 가끔 하는 일이므로, 그때 잠깐 읽고 마는 편이 이 앱의 원칙에 맞는다 (§4-5).
    public func searchBodies(matching query: String, in ids: [MemoID]) throws -> Set<MemoID> {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }

        var found: Set<MemoID> = []
        for id in ids {
            guard let text = try? String(contentsOf: memoFileURL(for: id), encoding: .utf8) else { continue }
            if text.localizedCaseInsensitiveContains(needle) {
                found.insert(id)
            }
        }
        return found
    }
}
