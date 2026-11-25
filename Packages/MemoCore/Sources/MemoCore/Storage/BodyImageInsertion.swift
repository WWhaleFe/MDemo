import Foundation

/// 메모 본문 글에 이미지 줄을 끼워 넣는다 (목록 창에서 메모를 열지 않고 사진을 받을 때).
///
/// 창 없이 저장소 경로로만 넣으므로, 편집기가 아닌 본문 글을 바로 다룬다. 순수 함수다.
public enum BodyImageInsertion {
    public enum Position: Sendable {
        /// 맨 앞. 본문 첫 줄이 제목(`# `)이면 그 바로 아래.
        case top
        /// 맨 끝.
        case bottom
    }

    /// `imageLines`(이미지 한 줄씩의 마크다운)를 본문에 넣은 새 본문.
    ///
    /// - Parameter skippingInserted: 맨 위에 넣을 때, 앞서 같은 방식으로 넣은 줄 수.
    ///   여러 장을 받을 때 받은 순서가 뒤집히지 않도록 그 뒤에 이어 붙인다.
    public static func inserting(
        _ imageLines: [String], into body: String, at position: Position, skippingInserted: Int = 0
    ) -> String {
        guard !imageLines.isEmpty else { return body }
        var lines = body.components(separatedBy: "\n")

        switch position {
        case .bottom:
            // 끝의 줄바꿈 하나는 줄이 아니라 끝 표시다. 있었다면 그대로 남긴다.
            let endsWithNewline = body.hasSuffix("\n")
            if endsWithNewline { lines.removeLast() }
            if body.isEmpty { lines = [] }
            lines.append(contentsOf: imageLines)
            return lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        case .top:
            var index = hasTitleLine(lines.first) ? 1 : 0
            index = min(lines.count, index + max(0, skippingInserted))
            if body.isEmpty { return imageLines.joined(separator: "\n") }
            lines.insert(contentsOf: imageLines, at: index)
            return lines.joined(separator: "\n")
        }
    }

    /// `# 제목` 꼴의 첫 줄인가.
    static func hasTitleLine(_ line: String?) -> Bool {
        guard let line else { return false }
        let hashes = line.prefix { $0 == "#" }
        return (1...6).contains(hashes.count) && line.dropFirst(hashes.count).first == " "
    }
}
