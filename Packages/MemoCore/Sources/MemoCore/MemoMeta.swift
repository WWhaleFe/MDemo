import Foundation

/// 메모의 메타데이터. 마크다운 파일 상단 YAML 프론트매터와 1:1 대응한다 (DOC-02).
///
/// 여기 담기는 값은 모두 **기기 간 공유 대상**이다.
/// 창 위치 · 크기 · 접힘처럼 기기마다 달라야 하는 값은 `DeviceMemoState`로 분리한다 (SYNC-07).
public struct MemoMeta: Hashable, Sendable, Codable {
    /// 프론트매터 스키마 버전. 포맷 변경 시 올리고 마이그레이션을 함께 넣는다.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: MemoID
    /// 소속 그룹. nil이면 미지정 (LST-03).
    public var group: String?
    /// 배경색 (16진수 문자열, 예: "#FFF3B0").
    public var colorHex: String
    /// 배경 레이어 알파. 하한 0.15 (OPA-01/03).
    public var backgroundAlpha: Double
    /// 텍스트 알파. 하한 0.3 (OPA-02/03).
    public var textAlpha: Double
    /// 플로팅 창으로 떠 있는가. 기기 간 공유되어 열린 창 미러링의 근거가 된다 (SYNC-08).
    public var isOpen: Bool
    /// 항상 위 고정 (WIN-03).
    public var isPinned: Bool
    public var created: Date
    /// 동기화 병합 시 최신본 판별 기준 (SYNC-06).
    public var modified: Date
    /// 충돌로 갈라져 나온 사본이면 원본 메모의 ID (SYNC-06).
    ///
    /// 두 기기에서 같은 메모를 동시에 고쳤을 때, 진 쪽을 버리지 않고 사본으로 남긴다.
    /// 리스트 창은 이 값이 있는 메모에 표시를 붙여 사용자가 정리할 수 있게 한다.
    public var conflictOf: MemoID?

    public init(
        schemaVersion: Int = MemoMeta.currentSchemaVersion,
        id: MemoID,
        group: String? = nil,
        colorHex: String = MemoColor.presets[0].hex,
        backgroundAlpha: Double = 0.95,
        textAlpha: Double = 1.0,
        isOpen: Bool = true,
        isPinned: Bool = true,
        created: Date = Date(),
        modified: Date = Date(),
        conflictOf: MemoID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.group = group
        self.colorHex = colorHex
        self.backgroundAlpha = MemoMeta.clampBackgroundAlpha(backgroundAlpha)
        self.textAlpha = MemoMeta.clampTextAlpha(textAlpha)
        self.isOpen = isOpen
        self.isPinned = isPinned
        self.created = created
        self.modified = modified
        self.conflictOf = conflictOf
    }

    /// 창을 완전히 잃어버리는 사고를 막기 위한 알파 하한선 (OPA-03).
    public static let backgroundAlphaRange: ClosedRange<Double> = 0.15...1.0
    public static let textAlphaRange: ClosedRange<Double> = 0.3...1.0

    public static func clampBackgroundAlpha(_ value: Double) -> Double {
        min(max(value, backgroundAlphaRange.lowerBound), backgroundAlphaRange.upperBound)
    }

    public static func clampTextAlpha(_ value: Double) -> Double {
        min(max(value, textAlphaRange.lowerBound), textAlphaRange.upperBound)
    }
}
