import Foundation

/// 그림자 비교 전용 경계. 실제 저장소 쓰기는 호출자가 Swift에 맡긴다.
public enum ShadowBridge {
    public typealias Entry = ShadowEntry
    public typealias Operation = ShadowOp
    public static func tree(_ root: URL) throws -> [Entry] { try shadowTreeDigest(dir: root.path) }
    public static func load(_ root: URL, id: String) throws -> String { try shadowLoadDigest(root: root.path, id: id) }
    public static func summaries(_ root: URL, trash: Bool) throws -> [String: String] {
        let values = try trash ? shadowTrashSummaries(root: root.path) : shadowSummaries(root: root.path)
        return Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0.digest) })
    }
    public static func apply(_ root: URL, operation: Operation) throws { try shadowApply(workRoot: root.path, op: operation) }
}
