import Foundation
import MemoCore

/// iPhone 파일 앱 등에서 바로 열어 볼 수 있는 읽기용 사본을 만든다.
///
/// 로컬 데이터 폴더의 메모를 `<그룹 이름 또는 미분류>/<메모 제목>.md`로 풀어 놓는다.
/// 프론트매터는 빼고 본문만 담으며, 이미지는 일반 마크다운 앱이 읽도록 상대 경로로 고쳐 쓰고 함께 복사한다.
/// 앱이 만든 파일만 `.mdemo-readable.json`에 적어 두고, 그중 이번에 만들지 않은 것만 지운다.
/// 내용이 같으면 다시 쓰지 않아 iCloud 업로드를 줄인다.
public struct ReadableCopy: Sendable {
    public struct Result: Sendable, Equatable {
        /// 새로 쓰거나 내용이 바뀌어 다시 쓴 파일 수.
        public var written = 0
        /// 내용이 같아 건너뛴 파일 수.
        public var unchanged = 0
        /// 오래되어 지운 파일 수.
        public var removed = 0
    }

    public static let folderName = "MDemo 읽기용"
    public static let noticeFileName = "읽어 주세요.txt"
    public static let ungroupedFolderName = "미분류"
    public static let attachmentsFolderName = "첨부"
    public static let noticeText = "이 폴더는 MDemo가 만드는 읽기용 사본입니다. 맥마다 자기 이름의 폴더를 따로 만들며, 이 폴더는 그중 한 대의 것입니다. 여기서 고친 내용은 메모에 반영되지 않습니다. 고치려면 MDemo 폴더의 파일을 쓰세요.\n"
    static let maxNameLength = 80

    public let localRoot: URL
    public let outputRoot: URL

    public init(localRoot: URL, outputRoot: URL) {
        self.localRoot = localRoot
        self.outputRoot = outputRoot
    }

    /// iCloud Drive 안의 기본 출력 폴더. iCloud Drive가 꺼져 있으면 nil.
    public static func defaultOutputRoot(deviceName: String = currentDeviceName()) -> URL? {
        SyncService.iCloudDriveRoot()?
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(deviceFolderName(from: deviceName), isDirectory: true)
    }

    /// 이 맥의 이름. 시스템 설정의 컴퓨터 이름을 우선한다.
    public static func currentDeviceName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// 기기 이름을 폴더 이름으로 쓸 수 있게 다듬는다. 끝의 `.local`은 떼고, 비면 `이 맥`.
    public static func deviceFolderName(from raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".local") { name = String(name.dropLast(6)) }
        return sanitizeName(name, fallback: "이 맥")
    }

    // MARK: - 갱신

    /// 사본을 만든 파일 목록. 정리는 이 목록에 있는 파일만 지운다 (사용자가 넣은 파일은 건드리지 않는다).
    static let manifestFileName = ".mdemo-readable.json"

    private struct Manifest: Codable {
        var version = 1
        /// 출력 폴더 기준 상대 경로 -> 그 파일을 만든 메모 ID (메모와 무관한 파일은 빈 문자열).
        var files: [String: String] = [:]
    }

    @discardableResult
    public func update() throws -> Result {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        // 출력 폴더 자체가 링크여도 한 번 풀어 둔다. 이후 이 안쪽에서만 읽고 쓴다.
        let root = outputRoot.resolvingSymlinksInPath()

        var result = Result()
        /// 이번에 쓴(또는 그대로 둔) 파일의 출력 폴더 기준 상대 경로. 이름 비교는 대소문자를 가리지 않는다.
        var keep = Set<String>()
        /// 이번에 실제로 만들었거나 이미 있던 사본의 상대 경로와 주인 메모.
        var produced: [String: String] = [:]
        let oldManifest = loadManifest(root: root)

        /// 출력 폴더 안쪽의 안전한 주소. 경로 중간에 심볼릭 링크가 있으면 nil.
        func safeURL(_ relative: String) -> URL? {
            Self.safeURL(root: root, relative: relative)
        }

        func place(_ data: Data, at relative: String, owner: String) {
            keep.insert(relative.lowercased())
            guard let url = safeURL(relative) else { return }
            if let existing = try? Data(contentsOf: url), existing == data {
                produced[relative] = owner
                result.unchanged += 1
                return
            }
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                produced[relative] = owner
                result.written += 1
            } catch {
                // 한 파일이 실패해도 나머지는 계속 만든다.
            }
        }

        func placeCopy(of source: URL, at relative: String, owner: String) {
            keep.insert(relative.lowercased())
            guard let url = safeURL(relative) else { return }
            if fileManager.fileExists(atPath: url.path), fileManager.contentsEqual(atPath: source.path, andPath: url.path) {
                produced[relative] = owner
                result.unchanged += 1
                return
            }
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.removeItem(at: url)
                try fileManager.copyItem(at: source, to: url)
                produced[relative] = owner
                result.written += 1
            } catch {
                // 그림 하나가 실패해도 나머지는 계속 만든다.
            }
        }

        place(Data(Self.noticeText.utf8), at: Self.noticeFileName, owner: "")

        // 이름이 겹쳤을 때 번호가 흔들리지 않도록 순서를 고정한다.
        let scan = loadMemos()
        let memos = scan.memos.sorted {
            ($0.meta.created, $0.meta.id.rawValue) < ($1.meta.created, $1.meta.id.rawValue)
        }
        var usedNames: [String: Set<String>] = [:]
        var claimedAttachments: [String: URL] = [:]

        for memo in memos {
            let owner = memo.meta.id.rawValue
            let summary = MemoSummary(meta: memo.meta, preview: memo.body)
            let title = summary.title
            let folder = Self.sanitizeName(memo.meta.group ?? "", fallback: Self.ungroupedFolderName)
            let name = Self.uniqueName(
                Self.sanitizeName(title, fallback: "제목 없는 메모"),
                used: &usedNames[folder.lowercased(), default: []]
            )

            let rewritten = Self.rewriteImages(
                in: memo.body,
                memoID: memo.meta.id,
                memoDirectory: memo.directory,
                folder: folder
            ) { relative, source in
                // 같은 이름의 다른 그림이 이미 그 자리를 차지했으면 번호를 붙여 피한다.
                var candidate = relative
                var number = 2
                while let claimed = claimedAttachments[candidate.lowercased()], claimed != source {
                    let ext = (relative as NSString).pathExtension
                    let stem = (relative as NSString).deletingPathExtension
                    candidate = ext.isEmpty ? "\(stem)-\(number)" : "\(stem)-\(number).\(ext)"
                    number += 1
                }
                claimedAttachments[candidate.lowercased()] = source
                placeCopy(of: source, at: candidate, owner: owner)
                return candidate
            }

            let text = Self.compose(title: title, body: rewritten)
            place(Data(text.utf8), at: "\(folder)/\(name).md", owner: owner)
        }

        // 정리: 폴더를 훑지 못했으면 아무것도 지우지 않는다. 읽지 못한 메모의 옛 사본도 둔다.
        var newManifest = Manifest(files: produced)
        for (path, owner) in oldManifest.files {
            if produced[path] != nil { continue }
            let lowered = path.lowercased()
            let mustKeep = !scan.listed || scan.failed.contains(owner) || keep.contains(lowered)
            if mustKeep {
                newManifest.files[path] = owner
                continue
            }
            guard let url = Self.safeURL(root: root, relative: path) else {
                // 링크를 지나는 경로는 건드리지 않고, 기록에서만 뺀다.
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard !isDirectory.boolValue, (try? fileManager.removeItem(at: url)) != nil else {
                newManifest.files[path] = owner
                continue
            }
            result.removed += 1
            Self.removeEmptyParents(of: url, below: root)
        }
        saveManifest(newManifest, root: root, previous: oldManifest)
        return result
    }

    // MARK: - 기록

    private func loadManifest(root: URL) -> Manifest {
        let url = root.appendingPathComponent(Self.manifestFileName)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return Manifest() }
        return manifest
    }

    private func saveManifest(_ manifest: Manifest, root: URL, previous: Manifest) {
        guard manifest.files != previous.files || !FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.manifestFileName).path)
        else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: root.appendingPathComponent(Self.manifestFileName), options: .atomic)
    }

    // MARK: - 읽기

    private struct LoadedMemo {
        var meta: MemoMeta
        var body: String
        var directory: URL
    }

    private struct LoadResult {
        var memos: [LoadedMemo] = []
        /// 메모 폴더 목록을 읽었는가. 못 읽었으면 정리하면 안 된다.
        var listed = false
        /// 폴더는 있는데 읽지 못한 메모의 ID. 이 메모의 옛 사본은 지우지 않는다.
        var failed: Set<String> = []
    }

    /// 휴지통이 아닌 메모만 읽는다.
    private func loadMemos() -> LoadResult {
        var result = LoadResult()
        guard let destroyed = try? MemoPrivacyLedger.read("destroyed", root: localRoot),
              let localOnly = try? MemoPrivacyLedger.read("local-only", root: localRoot) else { return result }
        let privateIDs = destroyed.union(localOnly)
        let folder = localRoot.appendingPathComponent("memos", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return result }
        result.listed = true

        for directory in entries {
            let id = directory.lastPathComponent
            guard MemoID(rawValue: id).isValid, !privateIDs.contains(id) else { continue }
            let file = directory.appendingPathComponent("memo.md")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let document = try? FrontmatterCodec.decode(fileContents: text)
            else {
                result.failed.insert(id)
                continue
            }
            guard !document.meta.isLocked else { continue }
            result.memos.append(LoadedMemo(meta: document.meta, body: document.body, directory: directory))
        }
        return result
    }

    // MARK: - 경로 점검

    /// 출력 폴더 안쪽 주소를 돌려준다. 경로 조각에 `..`가 있거나, 이미 있는 조각 중 심볼릭 링크가 있으면 nil.
    static func safeURL(root: URL, relative: String) -> URL? {
        var url = root
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            guard component != "..", component != "." else { return nil }
            url.appendPathComponent(String(component))
            if let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType,
               type == .typeSymbolicLink {
                return nil
            }
        }
        return url
    }

    /// 파일을 지운 뒤 비어 버린 폴더를 출력 폴더 바로 아래까지 거슬러 올라가며 지운다.
    private static func removeEmptyParents(of file: URL, below root: URL) {
        var directory = file.deletingLastPathComponent()
        let rootPath = root.standardizedFileURL.path
        while directory.standardizedFileURL.path.hasPrefix(rootPath + "/") {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["남음"]
            guard contents.isEmpty else { return }
            guard (try? FileManager.default.removeItem(at: directory)) != nil else { return }
            directory = directory.deletingLastPathComponent()
        }
    }

    // MARK: - 순수 함수 (테스트 대상)

    /// 파일 이름으로 쓸 수 없는 글자를 `-`로 바꾸고, 앞뒤 공백과 점을 떼고, 80자로 자른다.
    public static func sanitizeName(_ raw: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let replaced = String(raw.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
        let trimSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))
        var name = replaced.trimmingCharacters(in: trimSet)
        if name.count > maxNameLength {
            name = String(name.prefix(maxNameLength)).trimmingCharacters(in: trimSet)
        }
        return name.isEmpty ? fallback : name
    }

    /// 같은 폴더에 같은 이름이 있으면 ` (2)` ` (3)`을 붙인다. 이름 비교는 대소문자를 가리지 않는다.
    public static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var number = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(base) (\(number))"
            number += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// 본문 맨 위에, 제목이 본문 첫 줄과 다르면 `# 제목` 한 줄을 붙인다.
    public static func compose(title: String, body: String) -> String {
        let firstLine = body
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        if cleaned == title { return body }
        return "# \(title)\n\n\(body)"
    }

    /// 이미지 줄 `![alt](attachments/x.png =260)`을 `![alt](첨부/<메모ID 앞 8자>-x.png)`로 고친다.
    ///
    /// 크기 표기는 지운다(일반 마크다운 앱 호환). 그림 파일이 없으면 줄을 그대로 둔다.
    /// 경로는 메모 파일이 있는 그룹 폴더 기준이므로 `<그룹 폴더>/첨부/...`는 파일 위치,
    /// 본문에 적는 값은 `첨부/...`다.
    /// `place`는 출력 폴더 기준 상대 경로(`<그룹>/첨부/<파일>`)와 원본 파일을 받아 복사하고, 실제 쓴 상대 경로를 돌려준다.
    static func rewriteImages(
        in body: String,
        memoID: MemoID,
        memoDirectory: URL,
        folder: String,
        place: (_ relative: String, _ source: URL) -> String
    ) -> String {
        let pattern = #"!\[([^\]]*)\]\(attachments/([^)]*?)(?: =\d+(?:x\d+)?)?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return body }

        let prefix = String(memoID.rawValue.prefix(8))
        let attachments = memoDirectory.appendingPathComponent("attachments", isDirectory: true)
        let nsBody = body as NSString
        var output = ""
        var cursor = 0

        for match in regex.matches(in: body, range: NSRange(location: 0, length: nsBody.length)) {
            output += nsBody.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length

            let whole = nsBody.substring(with: match.range)
            let alt = nsBody.substring(with: match.range(at: 1))
            let fileName = nsBody.substring(with: match.range(at: 2))
            let decoded = fileName.removingPercentEncoding ?? fileName
            let source = attachments.appendingPathComponent(decoded)

            guard !decoded.contains("/"), FileManager.default.fileExists(atPath: source.path) else {
                output += whole
                continue
            }
            let relative = place("\(folder)/\(attachmentsFolderName)/\(prefix)-\(decoded)", source)
            // 본문에는 메모 파일 기준 상대 경로를 쓴다.
            let local = String(relative.dropFirst(folder.count + 1))
            output += "![\(alt)](\(encodePath(local)))"
        }
        output += nsBody.substring(from: cursor)
        return output
    }

    /// 공백과 괄호처럼 마크다운 링크를 깨는 글자만 퍼센트 인코딩한다. 한글은 그대로 둔다.
    private static func encodePath(_ path: String) -> String {
        var result = ""
        for character in path {
            switch character {
            case " ": result += "%20"
            case "(": result += "%28"
            case ")": result += "%29"
            default: result.append(character)
            }
        }
        return result
    }
}
