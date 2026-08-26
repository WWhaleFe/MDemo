import Foundation

/// 기능 계층(SwiftUI) 자리표시자.
///
/// M3에서 리스트 창(LST-*, SRC-*, TRS-*), 이후 환경설정 창(SET-*)이 여기 들어온다.
/// 창은 열 때 만들고 닫을 때 완전히 해제한다 — 숨김 상태로 유지하면 메모리를 계속 점유한다.
public enum Features {
    public static let plannedMilestone = "M3: 리스트 창 (목록·그룹·검색·정렬·휴지통)"
}
