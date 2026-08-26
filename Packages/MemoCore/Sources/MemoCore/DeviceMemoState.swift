import Foundation

/// 기기마다 다르게 유지되어야 하는 창 상태 (SYNC-07).
///
/// 동기화 대상에서 제외되며 `device-state.json`에 기기별로 저장된다.
/// 맥미니의 모니터 좌표를 맥북 화면에 그대로 재현할 수 없으므로,
/// "무엇이 떠 있는가"(MemoMeta.isOpen)만 공유하고 "어디에 떠 있는가"는 여기서 관리한다.
public struct DeviceMemoState: Hashable, Sendable, Codable {
    /// 화면 좌표 [x, y, width, height].
    public var frame: [Double]
    /// 모니터 식별자. 모니터가 사라지면 화면 안으로 보정한다 (SYS-05).
    public var displayID: String?
    /// 제목 한 줄만 보이도록 접힌 상태 (WIN-08).
    public var isCollapsed: Bool

    public init(frame: [Double], displayID: String? = nil, isCollapsed: Bool = false) {
        self.frame = frame
        self.displayID = displayID
        self.isCollapsed = isCollapsed
    }
}
