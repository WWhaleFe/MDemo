import Foundation

/// 메모 파일 = YAML 프론트매터 + 마크다운 본문 (DOC-01, DOC-02).
public struct MemoDocument: Equatable, Sendable {
    public var meta: MemoMeta
    public var body: String
    /// 이 버전이 모르는 프론트매터 줄. 그대로 보존해 다시 기록한다.
    /// 구버전 앱이 신버전 파일을 열었다가 저장해도 데이터가 사라지지 않게 하는 장치다.
    public var unknownFrontmatterLines: [String]

    public init(meta: MemoMeta, body: String, unknownFrontmatterLines: [String] = []) {
        self.meta = meta
        self.body = body
        self.unknownFrontmatterLines = unknownFrontmatterLines
    }
}

public enum FrontmatterError: Error, Equatable {
    case missingOpeningDelimiter
    case missingClosingDelimiter
    case missingRequiredKey(String)
    case invalidValue(key: String, value: String)
}

/// 프론트매터를 읽고 쓴다.
///
/// **YAML 라이브러리를 쓰지 않는 이유**: 프론트매터 스키마는 우리가 정의하고 우리만 기록하며,
/// 중첩 구조 없이 평면 키만 쓰기로 정했다(알람도 `alarmAt`, `alarmRepeat`처럼 평면으로 편다).
/// 이 범위에서는 줄 단위 파서로 충분하고, 의존성 0을 유지하는 편이 초경량 원칙에 맞는다.
/// 스키마가 중첩을 요구할 만큼 커지면 그때 Yams 도입을 검토한다.
public enum FrontmatterCodec {
    private static let delimiter = "---"

    // MARK: - 읽기

    public static func decode(fileContents text: String) throws -> MemoDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")

        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == delimiter else {
            throw FrontmatterError.missingOpeningDelimiter
        }
        lines.removeFirst()

        guard let closingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == delimiter }) else {
            throw FrontmatterError.missingClosingDelimiter
        }

        let frontmatterLines = Array(lines[..<closingIndex])
        let body = lines[(closingIndex + 1)...].joined(separator: "\n")

        var fields: [String: String] = [:]
        var unknownLines: [String] = []
        let knownKeys = Set(Key.allCases.map(\.rawValue))

        for line in frontmatterLines {
            guard let (key, value) = splitKeyValue(line) else {
                // 빈 줄이나 주석은 버린다. 값이 있는 알 수 없는 줄만 보존한다.
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    unknownLines.append(line)
                }
                continue
            }
            if knownKeys.contains(key) {
                fields[key] = value
            } else {
                unknownLines.append(line)
            }
        }

        let meta = try makeMeta(from: fields)
        return MemoDocument(meta: meta, body: body, unknownFrontmatterLines: unknownLines)
    }

    private static func makeMeta(from fields: [String: String]) throws -> MemoMeta {
        guard let rawID = fields[Key.id.rawValue] else {
            throw FrontmatterError.missingRequiredKey(Key.id.rawValue)
        }
        let id = MemoID(rawValue: unquote(rawID))
        guard id.isValid else {
            throw FrontmatterError.invalidValue(key: Key.id.rawValue, value: rawID)
        }

        // 옛 파일도 지금 스키마로 올려서 읽는다.
        // v1 → v2는 제목이 하나 늘어난 것뿐이라, 없으면 비워 두면 그대로 맞는다.
        let fileVersion = fields[Key.schemaVersion.rawValue].flatMap { Int(unquote($0)) }
            ?? MemoMeta.currentSchemaVersion
        let schemaVersion = max(fileVersion, MemoMeta.currentSchemaVersion)

        let title = fields[Key.title.rawValue].map(unquote).flatMap { $0.isEmpty ? nil : $0 }

        let group = fields[Key.group.rawValue].map(unquote).flatMap { $0.isEmpty ? nil : $0 }

        let colorHex = fields[Key.color.rawValue].map(unquote) ?? MemoColor.presets[0].hex

        let created = fields[Key.created.rawValue].map(unquote).flatMap(parseDate) ?? Date()
        let modified = fields[Key.modified.rawValue].map(unquote).flatMap(parseDate) ?? created

        return MemoMeta(
            schemaVersion: schemaVersion,
            id: id,
            title: title,
            group: group,
            colorHex: colorHex,
            backgroundAlpha: fields[Key.bgAlpha.rawValue].flatMap { Double(unquote($0)) } ?? 0.95,
            textAlpha: fields[Key.textAlpha.rawValue].flatMap { Double(unquote($0)) } ?? 1.0,
            isOpen: parseBool(fields[Key.open.rawValue]) ?? true,
            isPinned: parseBool(fields[Key.pinned.rawValue]) ?? true,
            created: created,
            modified: modified,
            conflictOf: fields[Key.conflictOf.rawValue].map(unquote).map(MemoID.init(rawValue:))
        )
    }

    // MARK: - 쓰기

    public static func encode(_ document: MemoDocument) -> String {
        let meta = document.meta
        var lines: [String] = [delimiter]

        lines.append("\(Key.schemaVersion.rawValue): \(meta.schemaVersion)")
        lines.append("\(Key.id.rawValue): \(meta.id.rawValue)")
        if let title = meta.title, !title.isEmpty {
            lines.append("\(Key.title.rawValue): \(quote(title))")
        }
        if let group = meta.group, !group.isEmpty {
            lines.append("\(Key.group.rawValue): \(quote(group))")
        }
        lines.append("\(Key.color.rawValue): \(quote(meta.colorHex))")
        lines.append("\(Key.bgAlpha.rawValue): \(formatNumber(meta.backgroundAlpha))")
        lines.append("\(Key.textAlpha.rawValue): \(formatNumber(meta.textAlpha))")
        lines.append("\(Key.open.rawValue): \(meta.isOpen)")
        lines.append("\(Key.pinned.rawValue): \(meta.isPinned)")
        lines.append("\(Key.created.rawValue): \(formatDate(meta.created))")
        lines.append("\(Key.modified.rawValue): \(formatDate(meta.modified))")
        if let conflictOf = meta.conflictOf {
            lines.append("\(Key.conflictOf.rawValue): \(conflictOf.rawValue)")
        }

        // 모르는 필드를 마지막에 되돌려 놓는다 (상위 버전 호환).
        lines.append(contentsOf: document.unknownFrontmatterLines)

        lines.append(delimiter)
        lines.append(document.body)
        return lines.joined(separator: "\n")
    }

    // MARK: - 세부 구현

    private enum Key: String, CaseIterable {
        case schemaVersion
        case id
        case title
        case group
        case color
        case bgAlpha
        case textAlpha
        case open
        case pinned
        case created
        case modified
        case conflictOf
    }

    private static func splitKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.hasPrefix("#") else { return nil }
        return (key, value)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let inner = String(value.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value = value.map(unquote)?.lowercased() else { return nil }
        switch value {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    /// 소수점 뒤 불필요한 0을 없애 파일을 읽기 좋게 만든다.
    private static func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1_000_000 {
            return String(format: "%.1f", value)
        }
        return String(format: "%g", value)
    }

    /// 값 타입 포맷 스타일을 쓴다. ISO8601DateFormatter는 Sendable이 아니라
    /// 여러 스레드에서 목록을 읽을 때 안전하지 않다.
    ///
    /// 시각은 UTC로 기록한다 — 기기 간 병합(SYNC-06)에서 시간대가 섞이면 비교가 어긋난다.
    /// 소수점 이하까지 남기는 이유도 같다: 초 단위로 자르면 같은 초에 일어난 두 기기의 수정이
    /// 동률이 되어 어느 쪽이 최신인지 판정할 수 없다.
    private static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
    /// 소수점 없이 기록된 파일(손으로 편집했거나 다른 도구가 만든 경우)도 읽어들인다.
    private static let iso8601WholeSeconds = Date.ISO8601FormatStyle(timeZone: .gmt)

    private static func formatDate(_ date: Date) -> String {
        iso8601.format(date)
    }

    private static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: iso8601) { return date }
        return try? Date(text, strategy: iso8601WholeSeconds)
    }
}
