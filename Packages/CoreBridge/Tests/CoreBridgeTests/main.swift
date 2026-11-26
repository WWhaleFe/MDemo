import CoreBridge
import TestKit

let runner = TestRunner("CoreBridge")
runner.test("Rust 연결은 UInt32 경계값까지 왕복한다") { t in
    for value: UInt32 in [0, 1, 42, UInt32.max] {
        t.expectEqual(CoreInfo.ping(value), value)
    }
}
runner.test("핵심 버전은 0.16.0이다") { t in
    t.expectEqual(CoreInfo.version, "0.16.0")
}
runner.finish()
