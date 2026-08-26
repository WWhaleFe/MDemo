import Foundation

/// 외부 의존성 없이 동작하는 최소 테스트 러너.
///
/// 사용법:
/// ```swift
/// let runner = TestRunner("MemoCore")
/// runner.test("ULID는 26자다") { t in
///     t.expect(id.rawValue.count == 26, "실제 \(id.rawValue.count)자")
/// }
/// runner.finish()   // 실패가 있으면 종료 코드 1
/// ```
public final class TestRunner {
    private let suiteName: String
    private var currentFailures: [String] = []
    private var passedCount = 0
    private var failedCount = 0

    public init(_ suiteName: String) {
        self.suiteName = suiteName
        print("▸ \(suiteName)")
    }

    public func test(_ name: String, _ body: (TestRunner) throws -> Void) {
        currentFailures = []
        do {
            try body(self)
        } catch {
            currentFailures.append("예외 발생: \(error)")
        }

        if currentFailures.isEmpty {
            passedCount += 1
            print("  ✓ \(name)")
        } else {
            failedCount += 1
            print("  ✗ \(name)")
            for failure in currentFailures {
                print("      \(failure)")
            }
        }
    }

    public func expect(
        _ condition: Bool,
        _ description: @autoclosure () -> String = "조건이 참이 아님",
        line: Int = #line
    ) {
        if !condition {
            currentFailures.append("\(line)행: \(description())")
        }
    }

    public func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ description: @autoclosure () -> String = "",
        line: Int = #line
    ) {
        if actual != expected {
            let note = description()
            let suffix = note.isEmpty ? "" : " — \(note)"
            currentFailures.append("\(line)행: \(actual) != \(expected)\(suffix)")
        }
    }

    public func expectNil(_ value: Any?, _ description: @autoclosure () -> String = "nil이 아님", line: Int = #line) {
        if value != nil {
            currentFailures.append("\(line)행: \(description())")
        }
    }

    public func expectNotNil(_ value: Any?, _ description: @autoclosure () -> String = "nil임", line: Int = #line) {
        if value == nil {
            currentFailures.append("\(line)행: \(description())")
        }
    }

    /// 결과를 요약하고 실패가 있으면 종료 코드 1로 끝낸다.
    public func finish() -> Never {
        let total = passedCount + failedCount
        if failedCount == 0 {
            print("  \(total)개 통과\n")
            exit(0)
        } else {
            print("  \(passedCount)개 통과, \(failedCount)개 실패\n")
            exit(1)
        }
    }
}
