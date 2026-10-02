import Foundation
import MemoCore

/// 백업과 내보내기·가져오기 (DAT-04 ~ DAT-07).
///
/// 데이터가 마크다운 파일이라 백업은 사실상 폴더를 압축하는 일이다.
/// 앱이 사라져도 파일만 있으면 내용을 읽을 수 있다는 것이 이 앱의 저장 원칙이고,
/// 백업도 그 원칙을 따른다 — 압축을 풀면 그냥 마크다운 파일이 나온다.
public struct BackupService: Sendable {
    public let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    // MARK: - 백업 (DAT-04, DAT-05)

    /// 데이터 폴더 전체를 ZIP 하나로 묶는다.
    ///
    /// 압축은 시스템의 `ditto`에 맡긴다. 직접 구현하면 의존성이 늘고,
    /// macOS가 기본으로 갖고 있는 도구가 첨부 파일까지 그대로 담아 준다.
    public func exportBackup(to destination: URL) throws {
        try runDitto(arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", dataRoot.path, destination.path])
    }

    /// 백업에서 되돌린다.
    ///
    /// - `replaceExisting`이 true면 지금 데이터를 통째로 갈아 끼운다.
    /// - false면 기존 메모를 남기고 백업에 있는 것만 더한다 (DAT-05).
    public func importBackup(from archive: URL, replaceExisting: Bool) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDemoRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try runDitto(arguments: ["-x", "-k", archive.path, staging.path])

        guard let unpacked = try findDataFolder(in: staging) else {
            throw BackupError.archiveHasNoMemos
        }

        if replaceExisting {
            // 지금 것을 지우기 전에 옆으로 치워 둔다. 복원이 실패해도 원래 상태로 돌아올 수 있어야 한다.
            let backup = staging.appendingPathComponent("previous", isDirectory: true)
            if FileManager.default.fileExists(atPath: dataRoot.path) {
                try FileManager.default.moveItem(at: dataRoot, to: backup)
            }
            do {
                try FileManager.default.copyItem(at: unpacked, to: dataRoot)
            } catch {
                try? FileManager.default.removeItem(at: dataRoot)
                try? FileManager.default.moveItem(at: backup, to: dataRoot)
                throw error
            }
        } else {
            try mergeFolders(from: unpacked, into: dataRoot)
        }
    }

    /// 압축을 푼 폴더에서 memos가 들어 있는 자리를 찾는다.
    /// 백업을 만든 방식에 따라 한 겹 더 들어가 있을 수 있다.
    private func findDataFolder(in root: URL) throws -> URL? {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("memos").path) {
            return root
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        for entry in entries {
            if FileManager.default.fileExists(atPath: entry.appendingPathComponent("memos").path) {
                return entry
            }
        }
        return nil
    }

    /// 기존 메모를 지우지 않고 더한다. 같은 ID가 있으면 건드리지 않는다.
    private func mergeFolders(from source: URL, into destination: URL) throws {
        for folder in ["memos", "trash"] {
            let sourceFolder = source.appendingPathComponent(folder, isDirectory: true)
            let destinationFolder = destination.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

            let entries = (try? FileManager.default.contentsOfDirectory(
                at: sourceFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries {
                let target = destinationFolder.appendingPathComponent(entry.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: target.path) else { continue }
                try FileManager.default.copyItem(at: entry, to: target)
            }
        }
    }

    // MARK: - 메모 내보내기 (DAT-06)

    public enum ExportFormat: String, CaseIterable, Sendable {
        case markdown = "md"
        case html
        case plainText = "txt"

        public var label: String {
            switch self {
            case .markdown: return "마크다운 (.md)"
            case .html: return "HTML (.html)"
            case .plainText: return "텍스트 (.txt)"
            }
        }
    }

    /// 메모 하나를 파일로 내보낸다.
    public func export(_ document: MemoDocument, as format: ExportFormat, to destination: URL) throws {
        let text: String
        switch format {
        case .markdown:
            // 프론트매터는 앱 내부 정보라 빼고, 본문만 내보낸다.
            text = document.body
        case .plainText:
            text = MarkdownPlainTextRenderer.render(document.body)
        case .html:
            text = MarkdownHTMLRenderer.render(document.body, title: document.meta.group ?? "메모")
        }
        try Data(text.utf8).write(to: destination, options: .atomic)
    }

    // MARK: - 가져오기 (DAT-07)

    /// `.md`나 `.txt` 파일을 메모로 들여온다. 파일 이름은 첫 줄 제목으로 쓴다.
    public func makeDocument(fromImportedFile url: URL) throws -> MemoDocument {
        let raw = try String(contentsOf: url, encoding: .utf8)

        // 다른 도구가 붙인 프론트매터가 있으면 그대로 읽어 본다.
        if let existing = try? FrontmatterCodec.decode(fileContents: raw) {
            var document = existing
            document.meta.id = .generate()
            document.meta.isOpen = false
            return document
        }

        let name = url.deletingPathExtension().lastPathComponent
        let hasHeading = raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
        let body = hasHeading ? raw : "# \(name)\n\(raw)"

        return MemoDocument(
            meta: MemoMeta(id: .generate(), isOpen: false),
            body: body
        )
    }

    // MARK: - 도구

    private func runDitto(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw BackupError.compressionFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

public enum BackupError: Error, LocalizedError {
    case compressionFailed(String)
    case archiveHasNoMemos

    public var errorDescription: String? {
        switch self {
        case .compressionFailed(let message):
            return message.isEmpty ? "압축에 실패했습니다." : "압축에 실패했습니다: \(message)"
        case .archiveHasNoMemos:
            return "이 파일에서 메모 폴더를 찾지 못했습니다."
        }
    }
}
