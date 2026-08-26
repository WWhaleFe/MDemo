import Foundation
import MarkdownEngine
import TestKit

let runner = TestRunner("MarkdownEngine")

// MARK: - 규칙 구조

private struct FakeRule: InputRule {
    let id = "TEST-01"
    func match(line: String, caretOffset: Int) -> InputRuleMatch? {
        line.hasPrefix("@ ") ? InputRuleMatch(range: 0..<2, replacement: "", style: .quote) : nil
    }
}

runner.test("등록한 규칙만으로 변환이 결정된다") { t in
    var set = InputRuleSet()
    t.expectNil(set.firstMatch(line: "@ 테스트", caretOffset: 2), "규칙이 없으면 변환도 없어야 한다")

    set.register(FakeRule())
    t.expectNotNil(set.firstMatch(line: "@ 테스트", caretOffset: 2), "등록한 규칙이 동작하지 않음")
    t.expectNil(set.firstMatch(line: "일반 문장", caretOffset: 0))
}

// MARK: - 블록 규칙 (MD-01 ~ MD-04)

runner.test("제목 기호를 치면 제목으로 바뀌고 기호는 사라진다 (MD-01)") { t in
    let rule = HeadingRule()
    let match = rule.match(line: "# 제목입니다", caretOffset: 2)
    t.expect(match?.style == .heading(level: 1))
    t.expectEqual(match?.replacement, "", "기호는 화면에서 숨겨야 한다")

    t.expect(rule.match(line: "### 소제목", caretOffset: 4)?.style == .heading(level: 3))
    t.expectNil(rule.match(line: "####### 일곱개", caretOffset: 8), "제목은 6단계까지만 있다")
    t.expectNil(rule.match(line: "#공백없음", caretOffset: 1), "공백 없이는 제목이 아니다")
}

runner.test("이미 쓴 줄은 커서가 딴 데 있으면 건드리지 않는다") { t in
    let rule = HeadingRule()
    t.expectNil(rule.match(line: "# 제목입니다", caretOffset: 7), "커서가 기호 뒤가 아니면 변환하지 않는다")
}

runner.test("글머리 기호와 번호 목록 (MD-02, MD-03)") { t in
    t.expect(BulletListRule().match(line: "- 사과", caretOffset: 2)?.style == .bulletList)
    t.expect(BulletListRule().match(line: "* 사과", caretOffset: 2)?.style == .bulletList)
    t.expect(OrderedListRule().match(line: "1. 첫째", caretOffset: 3)?.style == .orderedList)
    t.expect(OrderedListRule().match(line: "12. 열둘", caretOffset: 4)?.style == .orderedList)
    t.expectNil(OrderedListRule().match(line: "1.공백없음", caretOffset: 2))
}

runner.test("체크박스가 글머리 기호보다 먼저 잡힌다 (MD-04)") { t in
    // "- [ ] "는 "- "로도 읽히므로 순서가 중요하다
    t.expectNil(BulletListRule().match(line: "- [ ] 장보기", caretOffset: 2), "체크박스를 글머리로 잡으면 안 된다")
    t.expect(CheckboxRule().match(line: "- [ ] 장보기", caretOffset: 6)?.style == .checkbox(checked: false))
    t.expect(CheckboxRule().match(line: "- [x] 완료", caretOffset: 6)?.style == .checkbox(checked: true))
}

// MARK: - 인라인 규칙 (MD-05 ~ MD-09)

runner.test("굵게·기울임·취소선·형광·코드 변환 (MD-05~09)") { t in
    let cases: [(String, InlineStyle, PairedDelimiterRule)] = [
        ("**굵게**", .bold, .bold),
        ("*기울임*", .italic, .italic),
        ("~~취소~~", .strikethrough, .strikethrough),
        ("==형광==", .highlight, .highlight),
        ("`코드`", .inlineCode, .inlineCode),
    ]
    for (input, expectedStyle, rule) in cases {
        let match = rule.match(line: input, caretOffset: input.count)
        t.expectNotNil(match, "\(input) 변환 실패")
        t.expect(match?.style == expectedStyle, "\(input) 스타일 불일치")
        t.expect(match?.replacement.contains("*") == false || expectedStyle == .inlineCode, "기호가 남았다")
    }
}

runner.test("굵게가 기울임보다 먼저 검사된다") { t in
    let line = "**굵게**"
    let match = InputRuleSet.m1.firstMatch(line: line, caretOffset: line.count)
    t.expect(match?.style == .bold, "**가 *로 잘못 잡혔다")
}

runner.test("빈 기호 쌍은 변환하지 않는다") { t in
    t.expectNil(PairedDelimiterRule.bold.match(line: "****", caretOffset: 4), "내용 없는 기호는 변환 대상이 아니다")
    t.expectNil(PairedDelimiterRule.bold.match(line: "**  **", caretOffset: 6), "공백뿐인 내용도 마찬가지")
}

runner.test("한글도 동일하게 변환된다 (NFR-08)") { t in
    let line = "**안녕하세요**"
    let match = PairedDelimiterRule.bold.match(line: line, caretOffset: line.count)
    t.expectEqual(match?.replacement, "안녕하세요")
}

runner.test("굵게+기울임(***)이 왕복해도 기호가 늘어나지 않는다") { t in
    let source = "***강조***"
    let parsed = MarkdownParser.parse(source)
    t.expectEqual(MarkdownSerializer.serialize(parsed), source)
    t.expect(parsed[0].spans.first?.styles.contains([.bold, .italic]) == true)
}

// MARK: - 직렬화 (DOC-01, CHK-05)

runner.test("서식은 표준 마크다운 기호로 저장된다") { t in
    let lines = [
        StyledLine(block: .heading(level: 2), text: "회의록"),
        StyledLine(block: .checkbox(indent: 0, checked: false), text: "자료 준비"),
        StyledLine(block: .checkbox(indent: 1, checked: true), text: "출력"),
        StyledLine(block: .bullet(indent: 0), text: "기타"),
        StyledLine(block: .ordered(indent: 0, number: 1), text: "첫째"),
        StyledLine(spans: [
            StyledSpan(text: "보통 "),
            StyledSpan(text: "굵게", styles: .bold),
            StyledSpan(text: " 그리고 "),
            StyledSpan(text: "형광", styles: .highlight),
        ]),
    ]
    let expected = """
    ## 회의록
    - [ ] 자료 준비
      - [x] 출력
    - 기타
    1. 첫째
    보통 **굵게** 그리고 ==형광==
    """
    t.expectEqual(MarkdownSerializer.serialize(lines), expected)
}

runner.test("겹친 서식은 항상 같은 순서로 감싼다 (저장 결과 안정성)") { t in
    let span = StyledSpan(text: "글자", styles: [.bold, .italic, .strikethrough])
    let line = StyledLine(spans: [span])
    let once = MarkdownSerializer.serialize([line])
    t.expectEqual(once, "***~~글자~~***")

    // 한 번 더 왕복해도 같은 문자열이어야 한다 — 아니면 저장할 때마다 파일이 바뀌어
    // 동기화가 헛된 충돌을 만든다 (SYNC-06)
    let reparsed = MarkdownParser.parse(once)
    t.expectEqual(MarkdownSerializer.serialize(reparsed), once)
}

// MARK: - 왕복 (파서 ↔ 직렬화)

runner.test("마크다운을 읽고 다시 쓰면 원본과 같다") { t in
    let samples = [
        "# 제목",
        "## 소제목",
        "- 사과\n- 배",
        "1. 첫째\n2. 둘째",
        "- [ ] 할 일\n- [x] 끝난 일",
        "  - 들여쓴 항목",
        "**굵게** 그리고 *기울임*",
        "~~취소선~~과 ==형광==",
        "`코드` 조각",
        "> 인용문",
        "---",
        "그냥 문단입니다",
        "한글 **굵게** 섞인 문장",
        "",
    ]
    for sample in samples {
        let roundTripped = MarkdownSerializer.serialize(MarkdownParser.parse(sample))
        t.expectEqual(roundTripped, sample, "왕복 실패")
    }
}

runner.test("코드 구간 안의 기호는 서식으로 해석되지 않는다") { t in
    let parsed = MarkdownParser.parse("`**별표**`")
    let spans = parsed[0].spans
    t.expectEqual(spans.count, 1)
    t.expectEqual(spans.first?.text, "**별표**", "코드 안 기호가 서식으로 먹혔다")
    t.expect(spans.first?.styles.contains(.code) == true)
}

runner.test("짝이 없는 기호는 그냥 글자로 남는다") { t in
    let parsed = MarkdownParser.parse("2 * 3 = 6")
    t.expectEqual(parsed[0].plainText, "2 * 3 = 6", "곱셈 기호가 서식으로 먹히면 안 된다")
    t.expectEqual(MarkdownSerializer.serialize(parsed), "2 * 3 = 6")
}

runner.test("여러 줄 문서 전체가 왕복된다") { t in
    let document = """
    # 장보기

    - [ ] 우유
    - [x] 계란
      - [ ] 대란으로

    **중요**: 오늘까지
    """
    t.expectEqual(MarkdownSerializer.serialize(MarkdownParser.parse(document)), document)
}

runner.finish()
