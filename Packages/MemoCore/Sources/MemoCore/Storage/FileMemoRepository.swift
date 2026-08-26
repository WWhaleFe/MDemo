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

    /// 기본 데이터 폴더: ~/Library/Application Support/MemoApp/Data
    public static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MemoApp/Data", isDirectory: true)
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

        let destination = rootDirectory
            .appendingPathComponent(Self.trashFolder, isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // 첨부 폴더까지 통째로 따라간다 (TRS-05).
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
