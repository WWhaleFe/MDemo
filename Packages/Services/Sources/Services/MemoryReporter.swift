import Foundation

/// 현재 프로세스의 실제 메모리 사용량을 읽는다.
///
/// 메모리 최소화가 이 앱의 제1 요구사항이므로(설계서 §4-5),
/// 개발 중 어느 시점에나 사용량을 눈으로 확인할 수 있도록 앱에 내장한다.
/// 측정 게이트: 상주 50MB 이하(NFR-09), 메모 10개 120MB 이하(NFR-02).
public enum MemoryReporter {
    /// 물리 메모리 점유량(바이트). 읽기 실패 시 nil.
    public static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// "42.3 MB" 형태의 표시용 문자열.
    public static func formattedFootprint() -> String {
        guard let bytes = footprintBytes() else { return "측정 불가" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }
}
