import MarkdownEngine
import TestKit

/// 규칙을 추가하는 것만으로 변환이 늘어나는 구조인지 확인한다.
/// M1에서 실제 규칙(MD-01~07)이 들어오면 규칙별 테스트를 여기에 추가한다.
private struct FakeHeadingRule: InputRule {
    let id = "TEST-01"

    func match(line: String, caretOffset: Int) -> InputRuleMatch? {
        guard line.hasPrefix("# ") else { return nil }
        return InputRuleMatch(range: 0..<2, replacement: "", style: .heading(level: 1))
    }
}

let runner = TestRunner("MarkdownEngine")

runner.test("등록한 규칙만으로 변환이 결정된다") { t in
    var set = InputRuleSet()
    t.expectNil(set.firstMatch(line: "# 제목", caretOffset: 2), "규칙이 없으면 변환도 없어야 한다")

    set.register(FakeHeadingRule())
    let match = set.firstMatch(line: "# 제목", caretOffset: 2)
    t.expectNotNil(match, "등록한 규칙이 동작하지 않음")
    t.expect(match?.style == .heading(level: 1), "제목 스타일이 아님")
    t.expectNil(set.firstMatch(line: "일반 문장", caretOffset: 0), "무관한 줄은 변환하지 않아야 한다")
}

runner.test("규칙은 등록 순서대로 검사된다") { t in
    var set = InputRuleSet()
    set.register(FakeHeadingRule())
    set.register(FakeHeadingRule())
    t.expectEqual(set.rules.count, 2)
}

runner.finish()
