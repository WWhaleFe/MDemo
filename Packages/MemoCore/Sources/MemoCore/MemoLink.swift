import Foundation

/// 메모 사이 연결 종류 (설계서 §4).
public enum MemoLinkKind: String, Sendable, Codable, CaseIterable {
    case line, flow, both, related, dashto, dashboth, contain, block, oppose, same

    public enum LineStyle: String, Sendable, Codable { case solid, dashed }
    public enum Arrows: String, Sendable, Codable { case none, forward, both }
    public var lineStyle: LineStyle { [.related, .dashto, .dashboth].contains(self) ? .dashed : .solid }
    public var arrows: Arrows {
        switch self {
        case .line, .related, .contain, .block, .oppose, .same: .none
        case .flow, .dashto: .forward
        case .both, .dashboth: .both
        }
    }
    public init(lineStyle: LineStyle, arrows: Arrows) {
        switch (lineStyle, arrows) {
        case (.solid, .none): self = .line
        case (.solid, .forward): self = .flow
        case (.solid, .both): self = .both
        case (.dashed, .none): self = .related
        case (.dashed, .forward): self = .dashto
        case (.dashed, .both): self = .dashboth
        }
    }
    public static let basic: [Self] = [.line, .flow, .both, .related, .dashto, .dashboth]
    public var group: Int { Self.allCases.firstIndex(of: self)! < 3 ? 0 : (Self.basic.contains(self) ? 1 : 2) }
    public var displayName: String {
        switch self {
        case .line: "연결"
        case .flow: "흐름"
        case .both: "상호"
        case .related: "관련"
        case .dashto: "참고"
        case .dashboth: "서로 참고"
        case .contain: "포함"
        case .block: "막힘"
        case .oppose: "반대"
        case .same: "같음"
        }
    }
    public var meaning: String {
        switch self {
        case .line: "같은 주제로 이어진 메모"
        case .flow: "다음 단계, 순서가 있는 이어짐"
        case .both: "서로 주고받는 대등한 관계"
        case .related: "느슨하게 관련된 메모"
        case .dashto: "이 메모가 저 메모를 참고하거나 기댐(화살표 쪽이 참고 대상)"
        case .dashboth: "서로를 참고하는 약한 양방향 관계"
        case .contain: "큰 주제(점 쪽)가 작은 메모를 품음"
        case .block: "이 일이 끝나야 저 일(⊣ 쪽)을 할 수 있음"
        case .oppose: "서로 부딪히는 생각 · 대안"
        case .same: "같은 내용 · 중복"
        }
    }
    public var title: String { displayName }
    public var help: String { "\(displayName) · \(meaning)" }
    public static func chipText(counts: [Self: Int]) -> String {
        let kinds = allCases.filter { $0 != .flow && counts[$0, default: 0] > 0 }
        var parts = kinds.prefix(2).map { "\($0.displayName) \(counts[$0]!)" }
        if kinds.count > 2 { parts.append("외 \(kinds.count - 2)") }
        return parts.joined(separator: " · ")
    }

}

/// 출발 메모의 프론트매터에 기록할 연결 (DOC-02).
public struct MemoLink: Hashable, Sendable, Codable {
    public var to: MemoID
    public var kind: MemoLinkKind
    public var label: String {
        didSet { label = Self.normalizedLabel(label) }
    }
    /// 알 수 없는 꼬리는 해석하지 않고 원문 그대로 보존한다.
    public var unknownSuffix: String
    public static func normalizedLabel(_ value: String) -> String { String(value.prefix(20)) }

    private enum CodingKeys: String, CodingKey { case to, kind, label, unknownSuffix }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(to: try values.decode(MemoID.self, forKey: .to),
                  kind: try values.decode(MemoLinkKind.self, forKey: .kind),
                  label: try values.decodeIfPresent(String.self, forKey: .label) ?? "",
                  unknownSuffix: try values.decodeIfPresent(String.self, forKey: .unknownSuffix) ?? "")
    }

    /// 모양은 기존 종류 토큰 하나로 보관해 서로 어긋나는 조합이 생기지 않게 한다.
    public var lineStyle: MemoLinkKind.LineStyle {
        get { kind.lineStyle }
        set { kind = MemoLinkKind(lineStyle: newValue, arrows: arrows) }
    }
    public var arrows: MemoLinkKind.Arrows {
        get { kind.arrows }
        set { kind = MemoLinkKind(lineStyle: lineStyle, arrows: newValue) }
    }
    public init(to: MemoID, lineStyle: MemoLinkKind.LineStyle, arrows: MemoLinkKind.Arrows) {
        self.init(to: to, kind: MemoLinkKind(lineStyle: lineStyle, arrows: arrows))
    }
    public init(to: MemoID, kind: MemoLinkKind, label: String = "", unknownSuffix: String = "") {
        self.to = to
        self.kind = kind
        self.label = Self.normalizedLabel(label)
        self.unknownSuffix = unknownSuffix
    }
}

/// 화면에 그릴 연결 한 줄. 흐름 의미는 실선 한쪽 화살표만 가진다.
public struct MemoEdge: Hashable, Sendable {
    public let from: MemoID
    public let to: MemoID
    public let kind: MemoLinkKind
    public let label: String
    public var displayLabel: String { label.isEmpty ? kind.displayName : "\(kind.displayName) · \(label)" }

    public init(from: MemoID, to: MemoID, kind: MemoLinkKind, label: String = "") {
        self.from = from
        self.to = to
        self.kind = kind
        self.label = MemoLink.normalizedLabel(label)
    }
}

/// flow 연결로 이어진 메모 묶음. memoIDs는 흐름 순서. id는 첫 메모의 id.
public struct MemoFlow: Hashable, Sendable, Identifiable {
    public let id: MemoID
    public let memoIDs: [MemoID]

    public init(id: MemoID, memoIDs: [MemoID]) {
        self.id = id
        self.memoIDs = memoIDs
    }
}
