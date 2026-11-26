import CoreBridge
import Foundation
import MarkdownEngine
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

// MARK: - 입력 규칙 (P5)

/// 대표 줄 200개와 커서 위치. 키 입력마다 불리는 경로라 평범한 글(걸리지 않는 줄)이 가장 많고,
/// 앞머리 · 닫는 기호 직후 · 줄 중간 커서 · 이모지와 결합 문자 줄을 고르게 섞는다.
func representativeLines() -> [(line: String, caret: Int)] {
    let sentences = [
        "오늘 회의에서 정한 내용을 정리합니다", "장보기 목록 우유 계란 두부", "Meeting notes for the weekly sync",
        "a", "한", "프로젝트 일정은 다음 주 월요일부터 시작하고 마감은 금요일 오후 여섯 시입니다 확인 부탁드립니다",
        "The quick brown fox jumps over the lazy dog and keeps running through the field until sunset",
        "메모 앱의 입력 규칙은 키를 칠 때마다 한 번씩 불립니다", "1234567890", "https://example.com/a/b?c=d",
    ]
    let blocks = ["# 제목", "## 소제목", "### 작은 제목", "- 사과", "* 별", "  - 하위 항목", "1. 첫째", "12. 열둘", "- [ ] 할 일", "[ ] 할 일", "[] 축약", "[x] 완료", "``` ", "\t- 탭 목록"]
    let inlines = ["**굵게**", "*기울임*", "~~취소~~", "==형광==", "`코드`", "앞 글 **굵게**", "앞 글 `code`", "한글 문장 중간 *강조*", "***섞음***", "**짝 없음"]
    let unicode = ["😀 이모지 줄", "👩‍👩‍👧‍👦 가족 **굵게**", "e\u{301} 결합 문자 줄", "한글 \u{1112}\u{1161}\u{11AB}", "🇰🇷 국기와 `코드`"]
    var result: [(String, Int)] = []
    // 평범한 글: 커서가 끝, 처음, 중간
    for sentence in sentences {
        let count = sentence.count
        for caret in [count, 0, count / 2, max(0, count - 1)] { result.append((sentence, caret)) }
    }
    // 평범한 글을 한 글자씩 쳐 가는 경로(걸리지 않음)
    let typing = "안녕하세요 오늘도 좋은 하루 보내세요 hello world"
    for length in stride(from: 1, through: typing.count, by: 2) {
        let prefix = String(typing.prefix(length))
        result.append((prefix, prefix.count))
    }
    for block in blocks {
        let markerEnd = block.firstIndex(of: " ").map { block.distance(from: block.startIndex, to: $0) + 1 } ?? block.count
        result.append((block, markerEnd))
        result.append((block, block.count))
        result.append((block, max(0, markerEnd - 1)))
    }
    for inline in inlines {
        result.append((inline, inline.count))
        result.append((inline, max(0, inline.count - 1)))
        result.append((inline + " 뒤 글", inline.count))
    }
    for line in unicode {
        result.append((line, line.count))
        result.append((line, line.count / 2))
    }
    var index = 0
    while result.count < 200 {
        let line = sentences[index % sentences.count] + " " + inlines[index % inlines.count]
        result.append((line, line.count))
        index += 1
    }
    return Array(result.prefix(200))
}

/// Swift 결과를 래퍼의 꼴로 바꾼다.
func swiftMatch(_ line: String, _ caret: Int) -> CoreInputRuleMatch? {
    guard let match = InputRuleSet.m1.firstMatch(line: line, caretOffset: caret) else { return nil }
    let outcome: CoreInputRuleMatch.Outcome
    switch match.outcome {
    case .block(.heading(let level)): outcome = .heading(level: level)
    case .block(.bullet(let indent)): outcome = .bullet(indent: indent)
    case .block(.ordered(let indent, let number)): outcome = .ordered(indent: indent, number: number)
    case .block(.checkbox(let indent, let checked)): outcome = .checkbox(indent: indent, checked: checked)
    case .block: outcome = .codeBlock
    case .inline(let styles): outcome = .inline(styles: styles.rawValue)
    }
    return CoreInputRuleMatch(range: match.range, replacement: match.replacement, outcome: outcome)
}

runner.test("입력 규칙: Rust 결과가 Swift InputRuleSet과 대표 줄 200개에서 모두 같다") { t in
    let lines = representativeLines()
    t.expectEqual(lines.count, 200)
    var matched = 0
    for (line, caret) in lines {
        let rust = InputRuleBridge.firstMatch(line: line, caretOffset: caret)
        let swift = swiftMatch(line, caret)
        t.expectEqual(rust, swift, "줄 \(line.debugDescription) 커서 \(caret)")
        if swift != nil { matched += 1 }
    }
    t.expect(matched >= 30, "걸리는 줄이 너무 적다: \(matched)")
}

// 지연 측정(P5, 계획표: 키 입력 1회 FFI 왕복 0.2ms 이하일 때만 이전). 릴리스 빌드에서 MDEMO_MEASURE=1일 때만 돌린다.
// 실행은 Scripts/measure-input-rule.sh.
if ProcessInfo.processInfo.environment["MDEMO_MEASURE"] == "1" {
    let lines = representativeLines()
    let rounds = 1_000
    func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func measure(_ name: String, _ call: (String, Int) -> Int) {
        var sink = 0
        // 예열
        for (line, caret) in lines { sink &+= call(line, caret) }
        // 평균: 전체 시간을 호출 수로 나눈다(시계 호출 비용이 섞이지 않는다).
        let start = now()
        for _ in 0..<rounds { for (line, caret) in lines { sink &+= call(line, caret) } }
        let total = now() - start
        let calls = rounds * lines.count
        // p99: 호출마다 시간을 잰다(시계 호출 비용이 조금 더해진다).
        var samples = [UInt64](repeating: 0, count: calls)
        var i = 0
        for _ in 0..<rounds {
            for (line, caret) in lines {
                let begin = now()
                sink &+= call(line, caret)
                samples[i] = now() - begin
                i += 1
            }
        }
        samples.sort()
        let mean = Double(total) / Double(calls) / 1000
        let p99 = Double(samples[calls * 99 / 100]) / 1000
        let maximum = Double(samples[calls - 1]) / 1000
        print(String(format: "MEASURE | %@ | %d | %.2f | %.2f | %.1f | sink %d", name, calls, mean, p99, maximum, sink & 1))
    }

    print("MEASURE | 구현 | 호출 수 | 평균 us | p99 us | 최대 us")
    measure("Swift 직접 호출") { line, caret in InputRuleSet.m1.firstMatch(line: line, caretOffset: caret)?.range.count ?? -1 }
    measure("Rust FFI 왕복") { line, caret in InputRuleBridge.firstMatch(line: line, caretOffset: caret)?.range.count ?? -1 }
    // 빈 호출(FFI 고정 비용 참고)
    measure("FFI 연결 확인(ping)") { _, caret in Int(CoreInfo.ping(UInt32(caret))) }
}
runner.finish()
