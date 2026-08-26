import Services
import TestKit

let runner = TestRunner("Services")

runner.test("메모리 사용량을 읽을 수 있다 (§4-5 측정 게이트의 기반)") { t in
    let bytes = MemoryReporter.footprintBytes()
    t.expectNotNil(bytes, "메모리 측정 실패")
    t.expect((bytes ?? 0) > 1_000_000, "프로세스 메모리가 1MB 미만일 수는 없다")
    t.expect(MemoryReporter.formattedFootprint().hasSuffix("MB"), "표시 형식이 MB가 아님")
}

runner.finish()
