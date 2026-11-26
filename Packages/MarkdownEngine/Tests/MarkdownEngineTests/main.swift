import Foundation
import MarkdownEngine
import TestKit

#if MDEMO_RUST_MARKDOWN_TEST
import MemoCore
RustMarkdownBackend.installIfRequested()
if CommandLine.arguments.contains("--rust-markdown") {
    precondition(MarkdownEngineBackend.current is RustMarkdownBackend)
}
#endif

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
        "divider", "quote", "table", "codeBlock",
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

// MARK: - 코드 박스 (MD-10)

runner.test("코드 박스는 울타리를 벗겨 내고 줄마다 코드 서식을 단다 (MD-10)") { t in
    let lines = MarkdownParser.parse("앞\n```\nlet x = 1\n# 주석 아님\n```\n뒤")
    t.expectEqual(lines.count, 4, "울타리 줄이 남았다: \(lines.map(\.block))")
    t.expectEqual(lines[1].block, .codeBlock)
    t.expectEqual(lines[2].block, .codeBlock)
    t.expectEqual(lines[3].block, .paragraph)

    // 코드 안의 #은 제목이 아니고, *는 기울임이 아니다.
    t.expectEqual(lines[2].spans.map(\.text).joined(), "# 주석 아님")
    t.expectEqual(lines[2].spans.first?.styles, [])
}

runner.test("코드 박스는 울타리를 되살려 저장된다 (MD-10, DOC-01)") { t in
    let markdown = "앞\n```\nlet x = 1\n*별표 그대로*\n```\n뒤"
    let roundTrip = MarkdownSerializer.serialize(MarkdownParser.parse(markdown))
    t.expectEqual(roundTrip, markdown, "왕복에서 코드가 달라졌다")
}

runner.test("``` 로 시작한 줄은 코드 박스로 바뀐다 (MD-10)") { t in
    let match = InputRuleSet.m1.firstMatch(
        InputRuleContext(content: "``` ", caretOffset: 4, block: .paragraph)
    )
    t.expectEqual(match?.outcome, .block(.codeBlock))
}

// MARK: - 번호 목록 표식 (MD-03)

runner.test("번호 목록은 단계마다 다른 꼴로 보인다 (MD-03)") { t in
    t.expectEqual(OrderedListMarker.text(number: 1, indent: 0), "1.")
    t.expectEqual(OrderedListMarker.text(number: 2, indent: 1), "b.")
    t.expectEqual(OrderedListMarker.text(number: 3, indent: 2), "iii.")
    // 네 번째 단계부터는 다시 처음 꼴로 돌아간다.
    t.expectEqual(OrderedListMarker.text(number: 4, indent: 3), "4.")

    t.expectEqual(OrderedListMarker.letters(27), "aa")
    t.expectEqual(OrderedListMarker.roman(9), "ix")
}

runner.test("단계가 달라도 파일에는 표준 번호로 적힌다 (DOC-01, DOC-04)") { t in
    let lines = [
        StyledLine(block: .ordered(indent: 0, number: 1), spans: [StyledSpan(text: "겉")]),
        StyledLine(block: .ordered(indent: 1, number: 2), spans: [StyledSpan(text: "속")]),
    ]
    t.expectEqual(MarkdownSerializer.serialize(lines), "1. 겉\n  2. 속")
}

// MARK: - 표 (MD-14)

runner.test("표는 구분 줄을 화면에서 빼고 저장할 때 되살린다 (MD-14)") { t in
    let markdown = "| 항목 | 내용 |\n| --- | --- |\n| 하나 | 1 |"
    let lines = MarkdownParser.parse(markdown)

    t.expectEqual(lines.count, 2, "구분 줄이 화면에 남았다: \(lines.count)줄")
    t.expectEqual(lines[0].block, .tableRow)
    t.expectEqual(lines[1].spans.map(\.text).joined(), "| 하나 | 1 |")

    t.expectEqual(MarkdownSerializer.serialize(lines), markdown, "왕복에서 표가 달라졌다")
}

runner.test("표 앞뒤의 본문은 표에 딸려 들어가지 않는다 (MD-14)") { t in
    let markdown = "앞\n| A | B |\n| --- | --- |\n| 1 | 2 |\n뒤"
    let lines = MarkdownParser.parse(markdown)
    t.expectEqual(lines.map(\.block), [.paragraph, .tableRow, .tableRow, .paragraph])
    t.expectEqual(MarkdownSerializer.serialize(lines), markdown)
}

runner.test("문장 가운데 세로줄은 표가 아니다 (MD-14)") { t in
    let lines = MarkdownParser.parse("가격은 1000원 | 수량은 2개")
    t.expectEqual(lines[0].block, .paragraph, "그냥 세로줄을 쓴 문장이 표가 됐다")
}

runner.test("표 뼈대는 제목 줄과 빈 줄로 만들어진다 (MD-14)") { t in
    let skeleton = MarkdownTable.skeleton(columns: 2, rows: 3)
    t.expectEqual(skeleton.count, 3)
    t.expectEqual(skeleton[0], "| 항목 | 내용 |")
    t.expect(MarkdownTable.isEmptyRow(skeleton[1]), "둘째 줄이 빈 행이 아니다: \(skeleton[1])")
    t.expectEqual(MarkdownTable.columnCount(of: skeleton[0]), 2)

    // 뼈대를 저장하면 구분 줄이 끼어들어 표준 마크다운이 된다.
    let lines = skeleton.map { StyledLine(block: .tableRow, spans: [StyledSpan(text: $0)]) }
    t.expectEqual(
        MarkdownSerializer.serialize(lines),
        "| 항목 | 내용 |\n| --- | --- |\n|  |  |\n|  |  |"
    )
}

runner.test("정렬 표시가 붙은 구분 줄도 알아본다 (MD-14)") { t in
    t.expect(MarkdownTable.isSeparatorRow("| :--- | ---: | :---: |"), "정렬 표시를 구분 줄로 보지 않았다")
    t.expect(!MarkdownTable.isSeparatorRow("| 하나 | 둘 |"), "내용 줄을 구분 줄로 봤다")
}

// MARK: - 글자 색 · 형광펜 색

runner.test("글자 색과 형광펜 색은 HTML 태그로 왕복한다") { t in
    let samples = [
        "<span style=\"color:#D93025\">빨간 글자</span>",
        "앞 <mark style=\"background:#A7D3FF\">파란 형광</mark> 뒤",
        "<span style=\"color:#1A73E8\">**굵은 파랑**</span>",
        "<span style=\"color:#188038\"><mark style=\"background:#FFB3D1\">초록 글자 분홍 칠</mark></span>",
        "==기본 노랑은 예전 그대로==",
    ]
    for sample in samples {
        let lines = MarkdownParser.parse(sample)
        t.expectEqual(MarkdownSerializer.serialize(lines), sample, "왕복이 깨졌다")
    }
}

runner.test("글자 색 태그를 읽으면 기호 없이 색만 남는다") { t in
    let spans = MarkdownParser.parse("<span style=\"color:#d93025\">빨강</span>과 <mark style=\"background:#a8e6a1\">초록</mark>")[0].spans
    t.expectEqual(spans.count, 3)
    t.expectEqual(spans.first?.text, "빨강")
    t.expectEqual(spans.first?.textColor, "#D93025", "색 표기는 대문자로 맞춘다")
    t.expectEqual(spans.last?.text, "초록")
    t.expect(spans.last?.styles.contains(.highlight) == true, "형광이 켜지지 않았다")
    t.expectEqual(spans.last?.highlightColor, "#A8E6A1")
}

runner.test("다른 도구가 쓴 색 태그 꼴도 읽는다") { t in
    let spans = MarkdownParser.parse("<mark style='background-color: #FFCC99;'>주황</mark>")[0].spans
    t.expectEqual(spans.first?.text, "주황")
    t.expectEqual(spans.first?.highlightColor, "#FFCC99")
}

runner.test("코드 안의 색 태그와 짝 없는 태그는 글자 그대로 둔다") { t in
    let code = "`<span style=\"color:#D93025\">x</span>`"
    t.expectEqual(MarkdownSerializer.serialize(MarkdownParser.parse(code)), code)
    let unclosed = "<span style=\"color:#D93025\">닫히지 않음"
    t.expectEqual(MarkdownParser.parse(unclosed)[0].spans.first?.textColor, nil)
    t.expectEqual(MarkdownSerializer.serialize(MarkdownParser.parse(unclosed)), unclosed)
}

// MARK: - 노션 호환 (클립보드)

runner.test("클립보드용 마크다운은 색 태그와 ==형광==을 빼고 목록은 4칸으로 들여 쓴다") { t in
    let lines = MarkdownParser.parse("- 하나\n  - <span style=\"color:#D93025\">빨강</span>과 ==노랑==\n    1. 셋")
    t.expectEqual(
        MarkdownSerializer.serialize(lines, flavor: .clipboard),
        "- 하나\n    - 빨강과 노랑\n        1. 셋"
    )
    // 파일 형식은 그대로다.
    t.expectEqual(
        MarkdownSerializer.serialize(lines),
        "- 하나\n  - <span style=\"color:#D93025\">빨강</span>과 ==노랑==\n    1. 셋"
    )
}

runner.test("붙여 넣은 글의 들여쓰기 단위(4칸·탭)를 알아서 단계로 바꾼다") { t in
    for sample in ["- 하나\n    - 둘\n        - 셋", "- 하나\n\t- 둘\n\t\t- 셋", "- 하나\n  - 둘\n    - 셋"] {
        let lines = PastedMarkdown.parse(sample)
        t.expectEqual(lines.map(\.block), [.bullet(indent: 0), .bullet(indent: 1), .bullet(indent: 2)], "단계가 틀렸다: \(sample)")
    }
}

runner.test("글자로 된 목록·체크박스 기호와 * · + · 1) 꼴도 받는다") { t in
    let lines = PastedMarkdown.parse("• 점\n☐ 할 일\n☑ 한 일\n* 별\n+ 더하기\n* [ ] 별 체크\n1) 괄호 번호\n❝ 인용\r\n")
    t.expectEqual(lines.map(\.block), [
        .bullet(indent: 0), .checkbox(indent: 0, checked: false), .checkbox(indent: 0, checked: true),
        .bullet(indent: 0), .bullet(indent: 0), .checkbox(indent: 0, checked: false),
        .ordered(indent: 0, number: 1), .quote,
    ])
}

runner.test("코드 박스 안의 들여쓰기와 기호는 건드리지 않는다") { t in
    let lines = PastedMarkdown.parse("```\n    - 그대로\n• 그대로\n```")
    t.expectEqual(lines.map(\.spans.first?.text), ["    - 그대로", "• 그대로"])
}

// MARK: - 이미지 (IMG-07, IMG-08)

runner.test("이미지 줄과 =너비 문법이 왕복해도 그대로다 (IMG-08)") { t in
    for sample in [
        "![스샷](attachments/a1b2c3d4.png =260)",
        "![](attachments/x.jpg)",
        "![표 그림](attachments/img-1.jpeg =1200)",
    ] {
        let lines = MarkdownParser.parse(sample)
        t.expectEqual(lines.count, 1)
        guard case .image(let image) = lines[0].block else {
            t.expect(false, "이미지 줄로 읽지 못함: \(sample)")
            continue
        }
        t.expectEqual(image.fileName, (image.path as NSString).lastPathComponent)
        t.expectEqual(MarkdownSerializer.serialize(lines), sample, "왕복이 달라졌다")
    }
    let sized = MarkdownImage.parse("![a](attachments/p.png =260)")
    t.expectEqual(sized?.width, 260)
    t.expectEqual(sized?.alt, "a")
    t.expectNil(MarkdownImage.parse("![a](attachments/p.png)")?.width)
}

runner.test("글 사이에 낀 이미지 문법과 퍼센트 너비는 일반 글자로 보존한다") { t in
    for sample in ["앞 ![a](attachments/p.png) 뒤", "![a](attachments/p.png =50%)"] {
        let lines = MarkdownParser.parse(sample)
        t.expectEqual(lines.map(\.block), [.paragraph])
        t.expectEqual(MarkdownSerializer.serialize(lines), sample)
    }
}

runner.test("이미지 줄 앞뒤 글과 섞여도 줄 구성이 유지된다") { t in
    let sample = "# 제목\n![a](attachments/p.png =100)\n본문"
    let lines = MarkdownParser.parse(sample)
    t.expectEqual(lines.count, 3)
    t.expectEqual(MarkdownSerializer.serialize(lines), sample)
}

runner.test("노션으로 복사할 때는 이미지 줄을 뺀다 (로컬 경로는 못 읽는다)") { t in
    let lines = MarkdownParser.parse("# 제목\n![a](attachments/p.png =100)\n본문")
    t.expectEqual(MarkdownSerializer.serialize(lines, flavor: .clipboard), "# 제목\n본문")
    t.expectEqual(
        MarkdownSerializer.serialize(lines, flavor: .file),
        "# 제목\n![a](attachments/p.png =100)\n본문"
    )
}

runner.test("설명의 대괄호와 줄바꿈은 문법을 깨지 않도록 뺀다") { t in
    let image = MarkdownImage(alt: "a]b[c\nd", path: "attachments/p.png", width: 0)
    t.expectEqual(image.alt, "abcd")
    t.expectEqual(image.width, 1)
    t.expectNotNil(MarkdownImage.parse(image.markdown))
}

runner.test("저장 기본 이름: 설명이 있으면 설명, 없으면 제목과 번호, 못 쓰는 글자는 -") { t in
    t.expectEqual(ImageSaveName.defaultName(alt: "영수증", memoTitle: "장부", ordinal: 2, fileExtension: "png"), "영수증.png")
    t.expectEqual(ImageSaveName.defaultName(alt: "", memoTitle: "장부", ordinal: 2, fileExtension: "jpg"), "장부 이미지 2.jpg")
    t.expectEqual(ImageSaveName.defaultName(alt: "", memoTitle: "9/1: 회의", ordinal: 1, fileExtension: "png"), "9-1- 회의 이미지 1.png")
    t.expectEqual(ImageSaveName.defaultName(alt: " ", memoTitle: nil, ordinal: 0, fileExtension: "png"), "메모 이미지 1.png")
    t.expectEqual(ImageSaveName.defaultName(alt: "a:b", memoTitle: nil, ordinal: 1, fileExtension: ""), "a-b")
}

// MARK: - OCR 마크다운 만들기

/// 위에서 `row`번째 줄(0이 맨 위)에 놓인 조각. 줄 간격 0.05, 기본 줄 높이 0.03.
func ocr(_ text: String, row: Double, x: Double = 0.1, height: Double = 0.03, width: Double = 0.3) -> OCRLine {
    OCRLine(text: text, x: x, y: 0.95 - row * 0.05, width: width, height: height)
}

runner.test("OCR: 빈 입력과 공백 조각은 빈 글") { t in
    t.expectEqual(OCRMarkdownBuilder.build(lines: [], mode: .markdown), "")
    t.expectEqual(OCRMarkdownBuilder.build(lines: [ocr("  ", row: 0)], mode: .plain), "")
}

runner.test("OCR: 입력 순서와 상관없이 위에서 아래로 읽는다") { t in
    let lines = [ocr("둘째", row: 1), ocr("첫째", row: 0), ocr("셋째", row: 2)]
    t.expectEqual(OCRMarkdownBuilder.build(lines: lines, mode: .plain), "첫째\n둘째\n셋째")
}

runner.test("OCR: 같은 높이의 조각은 왼쪽부터 한 줄로 합친다") { t in
    let lines = [
        ocr("세계", row: 0, x: 0.5), ocr("안녕", row: 0, x: 0.1),
        OCRLine(text: "다음 줄", x: 0.1, y: 0.95 - 0.05, width: 0.3, height: 0.03),
    ]
    // 세로 중심이 조금 어긋나도(줄 높이의 절반 이내) 같은 줄이다.
    let slanted = [
        OCRLine(text: "왼쪽", x: 0.1, y: 0.80, width: 0.2, height: 0.03),
        OCRLine(text: "오른쪽", x: 0.5, y: 0.805, width: 0.2, height: 0.03),
    ]
    t.expectEqual(OCRMarkdownBuilder.build(lines: lines, mode: .markdown), "안녕 세계\n다음 줄")
    t.expectEqual(OCRMarkdownBuilder.build(lines: slanted, mode: .plain), "왼쪽 오른쪽")
}

runner.test("OCR: 줄 간격이 중앙값의 1.6배를 넘으면 문단을 나눈다") { t in
    let lines = [ocr("가", row: 0), ocr("나", row: 1), ocr("다", row: 3), ocr("라", row: 4)]
    t.expectEqual(OCRMarkdownBuilder.build(lines: lines, mode: .plain), "가\n나\n\n다\n라")
    // 1.6배 이하의 간격은 같은 문단이다.
    let near = [ocr("가", row: 0), ocr("나", row: 1), ocr("다", row: 2), ocr("라", row: 3.5)]
    t.expectEqual(OCRMarkdownBuilder.build(lines: near, mode: .plain), "가\n나\n다\n라")
}

runner.test("OCR: 줄 높이로 제목을 알아본다 (1.45배 이상 #, 1.2배 이상 ##)") { t in
    let lines = [
        ocr("큰 제목", row: 0, height: 0.05), ocr("본문 하나", row: 1), ocr("중간 제목", row: 2, height: 0.04),
        ocr("본문 둘", row: 3), ocr("본문 셋", row: 4),
    ]
    let result = OCRMarkdownBuilder.build(lines: lines, mode: .markdown)
    t.expect(result.hasPrefix("# 큰 제목"), result)
    t.expect(result.contains("## 중간 제목"), result)
    t.expect(result.contains("\n본문 하나\n"), result)
    // 텍스트만 모드는 제목 표시를 붙이지 않는다.
    t.expect(!OCRMarkdownBuilder.build(lines: lines, mode: .plain).contains("#"))
}

runner.test("OCR: 모두 같은 높이면 제목이 없다") { t in
    let lines = [ocr("하나", row: 0), ocr("둘", row: 1)]
    t.expectEqual(OCRMarkdownBuilder.build(lines: lines, mode: .markdown), "하나\n둘")
}

runner.test("OCR: 줄머리 기호는 글머리 목록으로") { t in
    let lines = ["• 사과", "· 배", "▪ 귤", "◦ 감", "- 포도", "* 딸기"].enumerated().map { ocr($1, row: Double($0)) }
    t.expectEqual(
        OCRMarkdownBuilder.build(lines: lines, mode: .markdown),
        "- 사과\n- 배\n- 귤\n- 감\n- 포도\n- 딸기"
    )
    // 공백 없는 하이픈은 글의 일부다.
    t.expectEqual(OCRMarkdownBuilder.build(lines: [ocr("-5도", row: 0)], mode: .markdown), "-5도")
    // 텍스트만 모드는 기호를 그대로 둔다.
    t.expectEqual(OCRMarkdownBuilder.build(lines: [ocr("• 사과", row: 0)], mode: .plain), "• 사과")
}

runner.test("OCR: 번호는 1. 꼴로") { t in
    let lines = ["1. 하나", "2) 둘", "③ 셋", "⑩ 열"].enumerated().map { ocr($1, row: Double($0)) }
    t.expectEqual(OCRMarkdownBuilder.build(lines: lines, mode: .markdown), "1. 하나\n2. 둘\n3. 셋\n10. 열")
    // 소수나 금액은 번호가 아니다.
    t.expectEqual(OCRMarkdownBuilder.build(lines: [ocr("3.5달러", row: 0)], mode: .markdown), "3.5달러")
}

runner.test("OCR: 체크 기호는 체크리스트로") { t in
    let lines = ["☐ 할 일", "□ 둘", "▢ 셋", "☑ 끝", "✓ 완료", "✔ 확인", "☒ 취소", "■ 네모"]
        .enumerated().map { ocr($1, row: Double($0)) }
    t.expectEqual(
        OCRMarkdownBuilder.build(lines: lines, mode: .markdown),
        "- [ ] 할 일\n- [ ] 둘\n- [ ] 셋\n- [x] 끝\n- [x] 완료\n- [x] 확인\n- [x] 취소\n- [x] 네모"
    )
}

runner.test("OCR: 줄 높이의 1.5배 이상 안쪽에서 시작하는 목록은 두 칸 들인다") { t in
    let lines = [
        ocr("• 위", row: 0, x: 0.1), ocr("• 아래", row: 1, x: 0.1 + 0.03 * 1.6),
        ocr("• 살짝", row: 2, x: 0.1 + 0.03 * 1.4),
    ]
    t.expectEqual(OCRMarkdownBuilder.build(lines: lines, mode: .markdown), "- 위\n  - 아래\n- 살짝")
    // 목록이 아닌 줄은 안쪽에서 시작해도 들이지 않는다.
    t.expectEqual(
        OCRMarkdownBuilder.build(lines: [ocr("본문", row: 0, x: 0.1), ocr("들어간 글", row: 1, x: 0.4)], mode: .markdown),
        "본문\n들어간 글"
    )
}

runner.test("OCR: 제목 줄은 목록 기호가 있어도 제목으로 둔다") { t in
    let lines = [ocr("1. 개요", row: 0, height: 0.05), ocr("글", row: 1), ocr("글", row: 2)]
    t.expect(OCRMarkdownBuilder.build(lines: lines, mode: .markdown).hasPrefix("# 1. 개요"))
}

runner.test("H1 경로는 첨부 폴더의 파일 한 단계만 허용한다") { t in
    for path in ["attachments/.", "attachments/..", "attachments/", "attachments/a/b.png", "attachments/a\\b.png", "../a.png", "https://example.com/a.png"] {
        let source = "![설명](\(path))"
        t.expectNil(MarkdownImage.parse(source), source)
        t.expectEqual(MarkdownSerializer.serialize(MarkdownParser.parse(source)), source)
        t.expectEqual(MarkdownSerializer.serialize(MarkdownParser.parse(source), flavor: .clipboard), source)
    }
    t.expectNotNil(MarkdownImage.parse("![설명](attachments/a.png =120)"))
}

runner.finish()
