import Foundation
import MarkdownEngine
import TestKit

let runner = TestRunner("MarkdownEngine")

/// 문단 상태에서의 검사를 짧게 쓰기 위한 도우미.
func paragraph(_ content: String, caret: Int? = nil) -> InputRuleContext {
    InputRuleContext(content: content, caretOffset: caret ?? content.count, block: .paragraph)
}

// MARK: - 규칙 구조

private struct FakeRule: InputRule {
    let id = "TEST-01"
    func match(_ context: InputRuleContext) -> InputRuleMatch? {
        context.content.hasPrefix("@ ")
            ? InputRuleMatch(range: 0..<2, replacement: "", outcome: .block(.quote))
            : nil
    }
}

runner.test("등록한 규칙만으로 변환이 결정된다") { t in
    var set = InputRuleSet()
    t.expectNil(set.firstMatch(paragraph("@ 테스트")), "규칙이 없으면 변환도 없어야 한다")

    set.register(FakeRule())
    t.expectNotNil(set.firstMatch(paragraph("@ 테스트")), "등록한 규칙이 동작하지 않음")
    t.expectNil(set.firstMatch(paragraph("일반 문장")))
}

// MARK: - 블록 규칙 (MD-01 ~ MD-04)

runner.test("제목 기호를 치면 제목으로 바뀌고 기호는 사라진다 (MD-01)") { t in
    let rule = HeadingRule()
    let match = rule.match(paragraph("# 제목입니다", caret: 2))
    t.expect(match?.outcome == .block(.heading(level: 1)))
    t.expectEqual(match?.replacement, "", "기호는 화면에서 숨겨야 한다")

    t.expect(rule.match(paragraph("### 소제목", caret: 4))?.outcome == .block(.heading(level: 3)))
    t.expectNil(rule.match(paragraph("####### 일곱개", caret: 8)), "제목은 6단계까지만 있다")
    t.expectNil(rule.match(paragraph("#공백없음", caret: 1)), "공백 없이는 제목이 아니다")
}

runner.test("이미 쓴 줄은 커서가 딴 데 있으면 건드리지 않는다") { t in
    t.expectNil(HeadingRule().match(paragraph("# 제목입니다", caret: 7)), "커서가 기호 뒤가 아니면 변환하지 않는다")
}

runner.test("이미 서식이 걸린 줄에는 블록 규칙이 다시 적용되지 않는다") { t in
    let heading = InputRuleContext(content: "# 다시", caretOffset: 2, block: .heading(level: 1))
    t.expectNil(HeadingRule().match(heading), "제목 줄에서 또 제목 변환이 일어나면 안 된다")
}

runner.test("글머리 기호와 번호 목록 (MD-02, MD-03)") { t in
    t.expect(BulletListRule().match(paragraph("- 사과", caret: 2))?.outcome == .block(.bullet(indent: 0)))
    t.expect(BulletListRule().match(paragraph("* 사과", caret: 2))?.outcome == .block(.bullet(indent: 0)))
    t.expect(OrderedListRule().match(paragraph("1. 첫째", caret: 3))?.outcome == .block(.ordered(indent: 0, number: 1)))
    t.expect(OrderedListRule().match(paragraph("12. 열둘", caret: 4))?.outcome == .block(.ordered(indent: 0, number: 12)))
    t.expectNil(OrderedListRule().match(paragraph("1.공백없음", caret: 2)))
}

runner.test("들여쓴 목록은 단계가 기록된다 (CHK-03)") { t in
    t.expect(BulletListRule().match(paragraph("  - 하위", caret: 4))?.outcome == .block(.bullet(indent: 1)))
}

// 실제 입력에서 가장 흔한 경로다.
// `- `를 치는 순간 글머리 목록이 되어 버리므로, 사용자는 그 뒤에 `[ ] `만 칠 수 있다.
runner.test("글머리 목록에서 [ ] 를 치면 체크박스가 된다 (MD-04)") { t in
    let bullet = InputRuleContext(content: "[ ] 장보기", caretOffset: 4, block: .bullet(indent: 0))
    let match = CheckboxRule().match(bullet)
    t.expect(match?.outcome == .block(.checkbox(indent: 0, checked: false)), "글머리 → 체크박스 전환 실패")
    t.expectEqual(match?.range, 0..<4)

    let shorthand = InputRuleContext(content: "[] 장보기", caretOffset: 3, block: .bullet(indent: 0))
    t.expect(CheckboxRule().match(shorthand)?.outcome == .block(.checkbox(indent: 0, checked: false)), "[] 축약형도 받아야 한다")

    let checked = InputRuleContext(content: "[x] 완료", caretOffset: 4, block: .bullet(indent: 0))
    t.expect(CheckboxRule().match(checked)?.outcome == .block(.checkbox(indent: 0, checked: true)))

    let indented = InputRuleContext(content: "[ ] 하위", caretOffset: 4, block: .bullet(indent: 2))
    t.expect(CheckboxRule().match(indented)?.outcome == .block(.checkbox(indent: 2, checked: false)), "들여쓰기 단계가 유지돼야 한다")
}

runner.test("문단에서 - [ ] 를 통째로 붙여넣어도 체크박스가 된다 (MD-04)") { t in
    t.expect(CheckboxRule().match(paragraph("- [ ] 장보기", caret: 6))?.outcome == .block(.checkbox(indent: 0, checked: false)))
    t.expect(CheckboxRule().match(paragraph("- [x] 완료", caret: 6))?.outcome == .block(.checkbox(indent: 0, checked: true)))
    t.expectNil(BulletListRule().match(paragraph("- [ ] 장보기", caret: 2)), "체크박스를 글머리로 잡으면 안 된다")
}

// MARK: - 인라인 규칙 (MD-05 ~ MD-09)

runner.test("굵게·기울임·취소선·형광·코드 변환 (MD-05~09)") { t in
    let cases: [(String, InlineStyleTag, PairedDelimiterRule)] = [
        ("**굵게**", .bold, .bold),
        ("*기울임*", .italic, .italic),
        ("~~취소~~", .strikethrough, .strikethrough),
        ("==형광==", .highlight, .highlight),
        ("`코드`", .code, .inlineCode),
    ]
    for (input, expected, rule) in cases {
        let match = rule.match(paragraph(input))
        t.expectNotNil(match, "\(input) 변환 실패")
        t.expect(match?.outcome == .inline(expected), "\(input) 스타일 불일치")
    }
}

runner.test("굵게가 기울임보다 먼저 검사된다") { t in
    t.expect(InputRuleSet.m1.firstMatch(paragraph("**굵게**"))?.outcome == .inline(.bold), "**가 *로 잘못 잡혔다")
}

runner.test("빈 기호 쌍은 변환하지 않는다") { t in
    t.expectNil(PairedDelimiterRule.bold.match(paragraph("****")), "내용 없는 기호는 변환 대상이 아니다")
    t.expectNil(PairedDelimiterRule.bold.match(paragraph("**  **")), "공백뿐인 내용도 마찬가지")
}

runner.test("한글도 동일하게 변환된다 (NFR-08)") { t in
    t.expectEqual(PairedDelimiterRule.bold.match(paragraph("**안녕하세요**"))?.replacement, "안녕하세요")
}

runner.test("목록 안에서도 인라인 서식이 걸린다") { t in
    let bullet = InputRuleContext(content: "**중요**", caretOffset: 6, block: .bullet(indent: 0))
    t.expect(PairedDelimiterRule.bold.match(bullet)?.outcome == .inline(.bold))
}

// MARK: - 슬래시 명령 (SL-02, SL-04, SL-05)

runner.test("슬래시 명령은 한글과 영어 모두로 찾을 수 있다 (SL-05)") { t in
    let korean = SlashCommandCatalog.filter("체크")
    t.expect(korean.first?.id == "checkbox", "한글로 체크박스를 찾지 못했다")

    let english = SlashCommandCatalog.filter("check")
    t.expect(english.first?.id == "checkbox", "영어로 체크박스를 찾지 못했다")

    let todo = SlashCommandCatalog.filter("todo")
    t.expect(todo.first?.id == "checkbox", "todo로 체크박스를 찾지 못했다")
}

runner.test("앞에서부터 일치하는 명령이 위에 온다 (SL-02)") { t in
    let matches = SlashCommandCatalog.filter("제목")
    t.expect(matches.count >= 3, "제목 1~3이 모두 나와야 한다")
    t.expect(matches.first?.id.hasPrefix("heading") == true, "제목이 첫 결과가 아니다")
}

runner.test("빈 입력에는 전체 명령이 나오고, 없는 명령은 빈 목록이다") { t in
    t.expectEqual(SlashCommandCatalog.filter("").count, SlashCommandCatalog.standard.count)
    t.expectEqual(SlashCommandCatalog.filter("없는명령어").count, 0)
}

runner.test("기본 명령 세트에 필요한 항목이 모두 있다 (SL-04)") { t in
    let ids = Set(SlashCommandCatalog.standard.map(\.id))
    for required in ["checkbox", "bullet", "ordered", "heading1", "heading2", "heading3", "quote", "divider", "paragraph"] {
        t.expect(ids.contains(required), "\(required) 명령이 없다")
    }
}

runner.test("명령 순서는 글의 구조를 따라간다") { t in
    let expected = [
        "paragraph",
        "heading1", "heading2", "heading3",
        "ordered", "bullet", "checkbox",
        "divider", "quote",
    ]
    t.expectEqual(SlashCommandCatalog.standard.map(\.id), expected, "드롭다운 배치 순서가 바뀌었다")
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
    let line = StyledLine(spans: [StyledSpan(text: "글자", styles: [.bold, .italic, .strikethrough])])
    let once = MarkdownSerializer.serialize([line])
    t.expectEqual(once, "***~~글자~~***")

    // 한 번 더 왕복해도 같은 문자열이어야 한다 — 아니면 저장할 때마다 파일이 바뀌어
    // 동기화가 헛된 충돌을 만든다 (SYNC-06)
    t.expectEqual(MarkdownSerializer.serialize(MarkdownParser.parse(once)), once)
}

// MARK: - 왕복 (파서 ↔ 직렬화)

runner.test("마크다운을 읽고 다시 쓰면 원본과 같다") { t in
    let samples = [
        "# 제목", "## 소제목",
        "- 사과\n- 배",
        "1. 첫째\n2. 둘째",
        "- [ ] 할 일\n- [x] 끝난 일",
        "  - 들여쓴 항목",
        "**굵게** 그리고 *기울임*",
        "~~취소선~~과 ==형광==",
        "`코드` 조각", "> 인용문", "---",
        "그냥 문단입니다", "한글 **굵게** 섞인 문장", "",
    ]
    for sample in samples {
        t.expectEqual(MarkdownSerializer.serialize(MarkdownParser.parse(sample)), sample, "왕복 실패")
    }
}

runner.test("굵게+기울임(***)이 왕복해도 기호가 늘어나지 않는다") { t in
    let source = "***강조***"
    let parsed = MarkdownParser.parse(source)
    t.expectEqual(MarkdownSerializer.serialize(parsed), source)
    t.expect(parsed[0].spans.first?.styles.contains([.bold, .italic]) == true)
}

runner.test("코드 구간 안의 기호는 서식으로 해석되지 않는다") { t in
    let spans = MarkdownParser.parse("`**별표**`")[0].spans
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
