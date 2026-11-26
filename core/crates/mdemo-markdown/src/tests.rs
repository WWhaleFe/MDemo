//! Swift `MarkdownEngineTests`(61개)를 옮긴 단위 테스트. 이름은 Swift 시험 이름을 그대로 쓴다.

use crate::image_name;
use crate::input_rule::*;
use crate::ocr::{self, OcrLine, OcrMode};
use crate::parser;
use crate::pasted;
use crate::serializer::{serialize, Flavor};
use crate::slash;
use crate::styled::*;
use crate::table;
use BlockStyle as B;

/// 문단 상태에서의 검사를 짧게 쓰기 위한 도우미.
fn paragraph(content: &str, caret: Option<usize>) -> InputRuleContext {
    InputRuleContext::paragraph(content, caret.unwrap_or_else(|| crate::text::count(content)))
}

fn outcome(m: Option<InputRuleMatch>) -> Option<InputRuleOutcome> {
    m.map(|m| m.outcome)
}

fn block(b: BlockStyle) -> Option<InputRuleOutcome> {
    Some(InputRuleOutcome::Block(b))
}

fn inline(s: InlineStyleTag) -> Option<InputRuleOutcome> {
    Some(InputRuleOutcome::Inline(s))
}

fn file(lines: &[StyledLine]) -> String {
    serialize(lines, Flavor::File)
}

fn round_trip(markdown: &str) -> String {
    file(&parser::parse(markdown))
}

// MARK: - 규칙 구조

struct FakeRule;
impl InputRule for FakeRule {
    fn id(&self) -> &str {
        "TEST-01"
    }
    fn matches(&self, context: &InputRuleContext) -> Option<InputRuleMatch> {
        if crate::text::has_prefix(&context.content, "@ ") {
            Some(InputRuleMatch { range: 0..2, replacement: String::new(), outcome: InputRuleOutcome::Block(B::Quote) })
        } else {
            None
        }
    }
}

#[test]
fn 등록한_규칙만으로_변환이_결정된다() {
    let mut set = InputRuleSet::default();
    assert!(set.first_match(&paragraph("@ 테스트", None)).is_none(), "규칙이 없으면 변환도 없어야 한다");
    set.register(Box::new(FakeRule));
    assert!(set.first_match(&paragraph("@ 테스트", None)).is_some(), "등록한 규칙이 동작하지 않음");
    assert!(set.first_match(&paragraph("일반 문장", None)).is_none());
}

// MARK: - 블록 규칙 (MD-01 ~ MD-04)

#[test]
fn 제목_기호를_치면_제목으로_바뀌고_기호는_사라진다() {
    let rule = HeadingRule;
    let m = rule.matches(&paragraph("# 제목입니다", Some(2)));
    assert_eq!(m.as_ref().map(|m| m.outcome.clone()), block(B::Heading { level: 1 }));
    assert_eq!(m.unwrap().replacement, "", "기호는 화면에서 숨겨야 한다");
    assert_eq!(outcome(rule.matches(&paragraph("### 소제목", Some(4)))), block(B::Heading { level: 3 }));
    assert!(rule.matches(&paragraph("####### 일곱개", Some(8))).is_none(), "제목은 6단계까지만 있다");
    assert!(rule.matches(&paragraph("#공백없음", Some(1))).is_none(), "공백 없이는 제목이 아니다");
}

#[test]
fn 이미_쓴_줄은_커서가_딴_데_있으면_건드리지_않는다() {
    assert!(HeadingRule.matches(&paragraph("# 제목입니다", Some(7))).is_none());
}

#[test]
fn 이미_서식이_걸린_줄에는_블록_규칙이_다시_적용되지_않는다() {
    let heading = InputRuleContext::new("# 다시", 2, B::Heading { level: 1 });
    assert!(HeadingRule.matches(&heading).is_none(), "제목 줄에서 또 제목 변환이 일어나면 안 된다");
}

#[test]
fn 글머리_기호와_번호_목록() {
    assert_eq!(outcome(BulletListRule.matches(&paragraph("- 사과", Some(2)))), block(B::Bullet { indent: 0 }));
    assert_eq!(outcome(BulletListRule.matches(&paragraph("* 사과", Some(2)))), block(B::Bullet { indent: 0 }));
    assert_eq!(outcome(OrderedListRule.matches(&paragraph("1. 첫째", Some(3)))), block(B::Ordered { indent: 0, number: 1 }));
    assert_eq!(outcome(OrderedListRule.matches(&paragraph("12. 열둘", Some(4)))), block(B::Ordered { indent: 0, number: 12 }));
    assert!(OrderedListRule.matches(&paragraph("1.공백없음", Some(2))).is_none());
}

#[test]
fn 들여쓴_목록은_단계가_기록된다() {
    assert_eq!(outcome(BulletListRule.matches(&paragraph("  - 하위", Some(4)))), block(B::Bullet { indent: 1 }));
}

#[test]
fn 글머리_목록에서_체크박스_기호를_치면_체크박스가_된다() {
    let bullet = InputRuleContext::new("[ ] 장보기", 4, B::Bullet { indent: 0 });
    let m = CheckboxRule.matches(&bullet);
    assert_eq!(m.as_ref().map(|m| m.outcome.clone()), block(B::Checkbox { indent: 0, checked: false }), "글머리 → 체크박스 전환 실패");
    assert_eq!(m.unwrap().range, 0..4);

    let shorthand = InputRuleContext::new("[] 장보기", 3, B::Bullet { indent: 0 });
    assert_eq!(outcome(CheckboxRule.matches(&shorthand)), block(B::Checkbox { indent: 0, checked: false }), "[] 축약형도 받아야 한다");

    let checked = InputRuleContext::new("[x] 완료", 4, B::Bullet { indent: 0 });
    assert_eq!(outcome(CheckboxRule.matches(&checked)), block(B::Checkbox { indent: 0, checked: true }));

    let indented = InputRuleContext::new("[ ] 하위", 4, B::Bullet { indent: 2 });
    assert_eq!(outcome(CheckboxRule.matches(&indented)), block(B::Checkbox { indent: 2, checked: false }), "들여쓰기 단계가 유지돼야 한다");
}

#[test]
fn 문단에서_체크박스를_통째로_붙여넣어도_체크박스가_된다() {
    assert_eq!(outcome(CheckboxRule.matches(&paragraph("- [ ] 장보기", Some(6)))), block(B::Checkbox { indent: 0, checked: false }));
    assert_eq!(outcome(CheckboxRule.matches(&paragraph("- [x] 완료", Some(6)))), block(B::Checkbox { indent: 0, checked: true }));
    assert!(BulletListRule.matches(&paragraph("- [ ] 장보기", Some(2))).is_none(), "체크박스를 글머리로 잡으면 안 된다");
}

// MARK: - 인라인 규칙 (MD-05 ~ MD-09)

#[test]
fn 굵게_기울임_취소선_형광_코드_변환() {
    let cases = [
        ("**굵게**", InlineStyleTag::BOLD, PairedDelimiterRule::bold()),
        ("*기울임*", InlineStyleTag::ITALIC, PairedDelimiterRule::italic()),
        ("~~취소~~", InlineStyleTag::STRIKETHROUGH, PairedDelimiterRule::strikethrough()),
        ("==형광==", InlineStyleTag::HIGHLIGHT, PairedDelimiterRule::highlight()),
        ("`코드`", InlineStyleTag::CODE, PairedDelimiterRule::inline_code()),
    ];
    for (input, expected, rule) in cases {
        let m = rule.matches(&paragraph(input, None));
        assert!(m.is_some(), "{input} 변환 실패");
        assert_eq!(outcome(m), inline(expected), "{input} 스타일 불일치");
    }
}

#[test]
fn 굵게가_기울임보다_먼저_검사된다() {
    assert_eq!(outcome(InputRuleSet::m1().first_match(&paragraph("**굵게**", None))), inline(InlineStyleTag::BOLD), "**가 *로 잘못 잡혔다");
}

#[test]
fn 빈_기호_쌍은_변환하지_않는다() {
    assert!(PairedDelimiterRule::bold().matches(&paragraph("****", None)).is_none(), "내용 없는 기호는 변환 대상이 아니다");
    assert!(PairedDelimiterRule::bold().matches(&paragraph("**  **", None)).is_none(), "공백뿐인 내용도 마찬가지");
}

#[test]
fn 한글도_동일하게_변환된다() {
    assert_eq!(PairedDelimiterRule::bold().matches(&paragraph("**안녕하세요**", None)).unwrap().replacement, "안녕하세요");
}

#[test]
fn 목록_안에서도_인라인_서식이_걸린다() {
    let bullet = InputRuleContext::new("**중요**", 6, B::Bullet { indent: 0 });
    assert_eq!(outcome(PairedDelimiterRule::bold().matches(&bullet)), inline(InlineStyleTag::BOLD));
}

// MARK: - 슬래시 명령 (SL-02, SL-04, SL-05)

#[test]
fn 슬래시_명령은_한글과_영어_모두로_찾을_수_있다() {
    for query in ["체크", "check", "todo"] {
        assert_eq!(slash::filter_standard(query).first().map(|c| c.id.as_str()), Some("checkbox"), "{query}로 체크박스를 찾지 못했다");
    }
}

#[test]
fn 앞에서부터_일치하는_명령이_위에_온다() {
    let matches = slash::filter_standard("제목");
    assert!(matches.len() >= 3, "제목 1~3이 모두 나와야 한다");
    assert!(matches[0].id.starts_with("heading"), "제목이 첫 결과가 아니다");
}

#[test]
fn 빈_입력에는_전체_명령이_나오고_없는_명령은_빈_목록이다() {
    assert_eq!(slash::filter_standard("").len(), slash::standard().len());
    assert_eq!(slash::filter_standard("없는명령어").len(), 0);
}

#[test]
fn 기본_명령_세트에_필요한_항목이_모두_있다() {
    let ids: Vec<String> = slash::standard().into_iter().map(|c| c.id).collect();
    for required in ["checkbox", "bullet", "ordered", "heading1", "heading2", "heading3", "quote", "divider", "paragraph"] {
        assert!(ids.iter().any(|i| i == required), "{required} 명령이 없다");
    }
}

#[test]
fn 명령_순서는_글의_구조를_따라간다() {
    let expected = ["paragraph", "heading1", "heading2", "heading3", "ordered", "bullet", "checkbox", "divider", "quote", "table", "codeBlock"];
    let ids: Vec<String> = slash::standard().into_iter().map(|c| c.id).collect();
    assert_eq!(ids, expected, "드롭다운 배치 순서가 바뀌었다");
}

// MARK: - 직렬화 (DOC-01, CHK-05)

#[test]
fn 서식은_표준_마크다운_기호로_저장된다() {
    let lines = vec![
        StyledLine::with_text(B::Heading { level: 2 }, "회의록"),
        StyledLine::with_text(B::Checkbox { indent: 0, checked: false }, "자료 준비"),
        StyledLine::with_text(B::Checkbox { indent: 1, checked: true }, "출력"),
        StyledLine::with_text(B::Bullet { indent: 0 }, "기타"),
        StyledLine::with_text(B::Ordered { indent: 0, number: 1 }, "첫째"),
        StyledLine::new(
            B::Paragraph,
            vec![
                StyledSpan::plain("보통 "),
                StyledSpan::with_styles("굵게", InlineStyleTag::BOLD),
                StyledSpan::plain(" 그리고 "),
                StyledSpan::with_styles("형광", InlineStyleTag::HIGHLIGHT),
            ],
        ),
    ];
    let expected = "## 회의록\n- [ ] 자료 준비\n  - [x] 출력\n- 기타\n1. 첫째\n보통 **굵게** 그리고 ==형광==";
    assert_eq!(file(&lines), expected);
}

#[test]
fn 겹친_서식은_항상_같은_순서로_감싼다() {
    let styles = InlineStyleTag::BOLD | InlineStyleTag::ITALIC | InlineStyleTag::STRIKETHROUGH;
    let line = StyledLine::new(B::Paragraph, vec![StyledSpan::with_styles("글자", styles)]);
    let once = file(&[line]);
    assert_eq!(once, "***~~글자~~***");
    // 한 번 더 왕복해도 같은 문자열이어야 한다 - 아니면 저장할 때마다 파일이 바뀌어 동기화가 헛된 충돌을 만든다 (SYNC-06)
    assert_eq!(round_trip(&once), once);
}

// MARK: - 왕복 (파서 ↔ 직렬화)

#[test]
fn 마크다운을_읽고_다시_쓰면_원본과_같다() {
    let samples = [
        "# 제목", "## 소제목", "- 사과\n- 배", "1. 첫째\n2. 둘째", "- [ ] 할 일\n- [x] 끝난 일", "  - 들여쓴 항목",
        "**굵게** 그리고 *기울임*", "~~취소선~~과 ==형광==", "`코드` 조각", "> 인용문", "---", "그냥 문단입니다",
        "한글 **굵게** 섞인 문장", "",
    ];
    for sample in samples {
        assert_eq!(round_trip(sample), sample, "왕복 실패");
    }
}

#[test]
fn 굵게_기울임이_왕복해도_기호가_늘어나지_않는다() {
    let source = "***강조***";
    let parsed = parser::parse(source);
    assert_eq!(file(&parsed), source);
    assert!(parsed[0].spans[0].styles.contains(InlineStyleTag::BOLD | InlineStyleTag::ITALIC));
}

#[test]
fn 코드_구간_안의_기호는_서식으로_해석되지_않는다() {
    let spans = parser::parse("`**별표**`")[0].spans.clone();
    assert_eq!(spans.len(), 1);
    assert_eq!(spans[0].text, "**별표**", "코드 안 기호가 서식으로 먹혔다");
    assert!(spans[0].styles.contains(InlineStyleTag::CODE));
}

#[test]
fn 짝이_없는_기호는_그냥_글자로_남는다() {
    let parsed = parser::parse("2 * 3 = 6");
    assert_eq!(parsed[0].plain_text(), "2 * 3 = 6", "곱셈 기호가 서식으로 먹히면 안 된다");
    assert_eq!(file(&parsed), "2 * 3 = 6");
}

#[test]
fn 여러_줄_문서_전체가_왕복된다() {
    let document = "# 장보기\n\n- [ ] 우유\n- [x] 계란\n  - [ ] 대란으로\n\n**중요**: 오늘까지";
    assert_eq!(round_trip(document), document);
}

// MARK: - 코드 박스 (MD-10)

#[test]
fn 코드_박스는_울타리를_벗겨_내고_줄마다_코드_서식을_단다() {
    let lines = parser::parse("앞\n```\nlet x = 1\n# 주석 아님\n```\n뒤");
    assert_eq!(lines.len(), 4, "울타리 줄이 남았다: {:?}", lines.iter().map(|l| &l.block).collect::<Vec<_>>());
    assert_eq!(lines[1].block, B::CodeBlock);
    assert_eq!(lines[2].block, B::CodeBlock);
    assert_eq!(lines[3].block, B::Paragraph);
    // 코드 안의 #은 제목이 아니고, *는 기울임이 아니다.
    assert_eq!(lines[2].plain_text(), "# 주석 아님");
    assert_eq!(lines[2].spans[0].styles, InlineStyleTag::NONE);
}

#[test]
fn 코드_박스는_울타리를_되살려_저장된다() {
    let markdown = "앞\n```\nlet x = 1\n*별표 그대로*\n```\n뒤";
    assert_eq!(round_trip(markdown), markdown, "왕복에서 코드가 달라졌다");
}

#[test]
fn 세_따옴표로_시작한_줄은_코드_박스로_바뀐다() {
    let m = InputRuleSet::m1().first_match(&InputRuleContext::new("``` ", 4, B::Paragraph));
    assert_eq!(outcome(m), block(B::CodeBlock));
}

// MARK: - 번호 목록 표식 (MD-03)

#[test]
fn 번호_목록은_단계마다_다른_꼴로_보인다() {
    assert_eq!(OrderedListMarker::text(1, 0), "1.");
    assert_eq!(OrderedListMarker::text(2, 1), "b.");
    assert_eq!(OrderedListMarker::text(3, 2), "iii.");
    // 네 번째 단계부터는 다시 처음 꼴로 돌아간다.
    assert_eq!(OrderedListMarker::text(4, 3), "4.");
    assert_eq!(OrderedListMarker::letters(27), "aa");
    assert_eq!(OrderedListMarker::roman(9), "ix");
}

#[test]
fn 단계가_달라도_파일에는_표준_번호로_적힌다() {
    let lines = vec![
        StyledLine::new(B::Ordered { indent: 0, number: 1 }, vec![StyledSpan::plain("겉")]),
        StyledLine::new(B::Ordered { indent: 1, number: 2 }, vec![StyledSpan::plain("속")]),
    ];
    assert_eq!(file(&lines), "1. 겉\n  2. 속");
}

// MARK: - 표 (MD-14)

#[test]
fn 표는_구분_줄을_화면에서_빼고_저장할_때_되살린다() {
    let markdown = "| 항목 | 내용 |\n| --- | --- |\n| 하나 | 1 |";
    let lines = parser::parse(markdown);
    assert_eq!(lines.len(), 2, "구분 줄이 화면에 남았다: {}줄", lines.len());
    assert_eq!(lines[0].block, B::TableRow);
    assert_eq!(lines[1].plain_text(), "| 하나 | 1 |");
    assert_eq!(file(&lines), markdown, "왕복에서 표가 달라졌다");
}

#[test]
fn 표_앞뒤의_본문은_표에_딸려_들어가지_않는다() {
    let markdown = "앞\n| A | B |\n| --- | --- |\n| 1 | 2 |\n뒤";
    let lines = parser::parse(markdown);
    let blocks: Vec<BlockStyle> = lines.iter().map(|l| l.block.clone()).collect();
    assert_eq!(blocks, [B::Paragraph, B::TableRow, B::TableRow, B::Paragraph]);
    assert_eq!(file(&lines), markdown);
}

#[test]
fn 문장_가운데_세로줄은_표가_아니다() {
    let lines = parser::parse("가격은 1000원 | 수량은 2개");
    assert_eq!(lines[0].block, B::Paragraph, "그냥 세로줄을 쓴 문장이 표가 됐다");
}

#[test]
fn 표_뼈대는_제목_줄과_빈_줄로_만들어진다() {
    let skeleton = table::skeleton(2, 3);
    assert_eq!(skeleton.len(), 3);
    assert_eq!(skeleton[0], "| 항목 | 내용 |");
    assert!(table::is_empty_row(&skeleton[1]), "둘째 줄이 빈 행이 아니다: {}", skeleton[1]);
    assert_eq!(table::column_count_of(&skeleton[0]), 2);
    // 뼈대를 저장하면 구분 줄이 끼어들어 표준 마크다운이 된다.
    let lines: Vec<StyledLine> = skeleton.iter().map(|s| StyledLine::new(B::TableRow, vec![StyledSpan::plain(s)])).collect();
    assert_eq!(file(&lines), "| 항목 | 내용 |\n| --- | --- |\n|  |  |\n|  |  |");
}

#[test]
fn 정렬_표시가_붙은_구분_줄도_알아본다() {
    assert!(table::is_separator_row("| :--- | ---: | :---: |"), "정렬 표시를 구분 줄로 보지 않았다");
    assert!(!table::is_separator_row("| 하나 | 둘 |"), "내용 줄을 구분 줄로 봤다");
}

// MARK: - 글자 색 · 형광펜 색

#[test]
fn 글자_색과_형광펜_색은_html_태그로_왕복한다() {
    let samples = [
        "<span style=\"color:#D93025\">빨간 글자</span>",
        "앞 <mark style=\"background:#A7D3FF\">파란 형광</mark> 뒤",
        "<span style=\"color:#1A73E8\">**굵은 파랑**</span>",
        "<span style=\"color:#188038\"><mark style=\"background:#FFB3D1\">초록 글자 분홍 칠</mark></span>",
        "==기본 노랑은 예전 그대로==",
    ];
    for sample in samples {
        assert_eq!(round_trip(sample), sample, "왕복이 깨졌다");
    }
}

#[test]
fn 글자_색_태그를_읽으면_기호_없이_색만_남는다() {
    let spans = parser::parse("<span style=\"color:#d93025\">빨강</span>과 <mark style=\"background:#a8e6a1\">초록</mark>")[0].spans.clone();
    assert_eq!(spans.len(), 3);
    assert_eq!(spans[0].text, "빨강");
    assert_eq!(spans[0].text_color.as_deref(), Some("#D93025"), "색 표기는 대문자로 맞춘다");
    assert_eq!(spans[2].text, "초록");
    assert!(spans[2].styles.contains(InlineStyleTag::HIGHLIGHT), "형광이 켜지지 않았다");
    assert_eq!(spans[2].highlight_color.as_deref(), Some("#A8E6A1"));
}

#[test]
fn 다른_도구가_쓴_색_태그_꼴도_읽는다() {
    let spans = parser::parse("<mark style='background-color: #FFCC99;'>주황</mark>")[0].spans.clone();
    assert_eq!(spans[0].text, "주황");
    assert_eq!(spans[0].highlight_color.as_deref(), Some("#FFCC99"));
}

#[test]
fn 코드_안의_색_태그와_짝_없는_태그는_글자_그대로_둔다() {
    let code = "`<span style=\"color:#D93025\">x</span>`";
    assert_eq!(round_trip(code), code);
    let unclosed = "<span style=\"color:#D93025\">닫히지 않음";
    assert_eq!(parser::parse(unclosed)[0].spans[0].text_color, None);
    assert_eq!(round_trip(unclosed), unclosed);
}

// MARK: - 노션 호환 (클립보드)

#[test]
fn 클립보드용_마크다운은_색_태그와_형광을_빼고_목록은_4칸으로_들여_쓴다() {
    let lines = parser::parse("- 하나\n  - <span style=\"color:#D93025\">빨강</span>과 ==노랑==\n    1. 셋");
    assert_eq!(serialize(&lines, Flavor::Clipboard), "- 하나\n    - 빨강과 노랑\n        1. 셋");
    // 파일 형식은 그대로다.
    assert_eq!(file(&lines), "- 하나\n  - <span style=\"color:#D93025\">빨강</span>과 ==노랑==\n    1. 셋");
}

#[test]
fn 붙여_넣은_글의_들여쓰기_단위를_알아서_단계로_바꾼다() {
    for sample in ["- 하나\n    - 둘\n        - 셋", "- 하나\n\t- 둘\n\t\t- 셋", "- 하나\n  - 둘\n    - 셋"] {
        let blocks: Vec<BlockStyle> = pasted::parse(sample).iter().map(|l| l.block.clone()).collect();
        assert_eq!(blocks, [B::Bullet { indent: 0 }, B::Bullet { indent: 1 }, B::Bullet { indent: 2 }], "단계가 틀렸다: {sample}");
    }
}

#[test]
fn 글자로_된_목록_체크박스_기호와_별표_더하기_괄호_꼴도_받는다() {
    let lines = pasted::parse("• 점\n☐ 할 일\n☑ 한 일\n* 별\n+ 더하기\n* [ ] 별 체크\n1) 괄호 번호\n❝ 인용\r\n");
    let blocks: Vec<BlockStyle> = lines.iter().map(|l| l.block.clone()).collect();
    assert_eq!(
        blocks,
        [
            B::Bullet { indent: 0 }, B::Checkbox { indent: 0, checked: false }, B::Checkbox { indent: 0, checked: true },
            B::Bullet { indent: 0 }, B::Bullet { indent: 0 }, B::Checkbox { indent: 0, checked: false },
            B::Ordered { indent: 0, number: 1 }, B::Quote,
        ]
    );
}

#[test]
fn 코드_박스_안의_들여쓰기와_기호는_건드리지_않는다() {
    let lines = pasted::parse("```\n    - 그대로\n• 그대로\n```");
    let texts: Vec<String> = lines.iter().map(|l| l.spans[0].text.clone()).collect();
    assert_eq!(texts, ["    - 그대로", "• 그대로"]);
}

// MARK: - 이미지 (IMG-07, IMG-08)

#[test]
fn 이미지_줄과_너비_문법이_왕복해도_그대로다() {
    for sample in ["![스샷](attachments/a1b2c3d4.png =260)", "![](attachments/x.jpg)", "![표 그림](attachments/img-1.jpeg =1200)"] {
        let lines = parser::parse(sample);
        assert_eq!(lines.len(), 1);
        let BlockStyle::Image(image) = &lines[0].block else { panic!("이미지 줄로 읽지 못함: {sample}") };
        assert_eq!(image.file_name(), image.path.rsplit('/').next().unwrap());
        assert_eq!(file(&lines), sample, "왕복이 달라졌다");
    }
    let sized = MarkdownImage::parse("![a](attachments/p.png =260)").unwrap();
    assert_eq!(sized.width, Some(260));
    assert_eq!(sized.alt, "a");
    assert_eq!(MarkdownImage::parse("![a](attachments/p.png)").unwrap().width, None);
}

#[test]
fn 글_사이에_낀_이미지_문법과_퍼센트_너비는_일반_글자로_보존한다() {
    for sample in ["앞 ![a](attachments/p.png) 뒤", "![a](attachments/p.png =50%)"] {
        let lines = parser::parse(sample);
        let blocks: Vec<BlockStyle> = lines.iter().map(|l| l.block.clone()).collect();
        assert_eq!(blocks, [B::Paragraph]);
        assert_eq!(file(&lines), sample);
    }
}

#[test]
fn 이미지_줄_앞뒤_글과_섞여도_줄_구성이_유지된다() {
    let sample = "# 제목\n![a](attachments/p.png =100)\n본문";
    let lines = parser::parse(sample);
    assert_eq!(lines.len(), 3);
    assert_eq!(file(&lines), sample);
}

#[test]
fn 노션으로_복사할_때는_이미지_줄을_뺀다() {
    let lines = parser::parse("# 제목\n![a](attachments/p.png =100)\n본문");
    assert_eq!(serialize(&lines, Flavor::Clipboard), "# 제목\n본문");
    assert_eq!(file(&lines), "# 제목\n![a](attachments/p.png =100)\n본문");
}

#[test]
fn 설명의_대괄호와_줄바꿈은_문법을_깨지_않도록_뺀다() {
    let image = MarkdownImage::new("a]b[c\nd", "attachments/p.png", Some(0));
    assert_eq!(image.alt, "abcd");
    assert_eq!(image.width, Some(1));
    assert!(MarkdownImage::parse(&image.markdown()).is_some());
}

#[test]
fn 저장_기본_이름은_설명_제목과_번호_못_쓰는_글자는_하이픈() {
    assert_eq!(image_name::default_name("영수증", Some("장부"), 2, "png"), "영수증.png");
    assert_eq!(image_name::default_name("", Some("장부"), 2, "jpg"), "장부 이미지 2.jpg");
    assert_eq!(image_name::default_name("", Some("9/1: 회의"), 1, "png"), "9-1- 회의 이미지 1.png");
    assert_eq!(image_name::default_name(" ", None, 0, "png"), "메모 이미지 1.png");
    assert_eq!(image_name::default_name("a:b", None, 1, ""), "a-b");
}

// MARK: - OCR 마크다운 만들기

/// 위에서 `row`번째 줄(0이 맨 위)에 놓인 조각. 줄 간격 0.05, 기본 줄 높이 0.03.
fn o(text: &str, row: f64) -> OcrLine {
    oc(text, row, 0.1, 0.03)
}

fn oc(text: &str, row: f64, x: f64, height: f64) -> OcrLine {
    OcrLine::new(text, x, 0.95 - row * 0.05, 0.3, height)
}

fn md(lines: &[OcrLine]) -> String {
    ocr::build(lines, OcrMode::Markdown)
}

fn plain(lines: &[OcrLine]) -> String {
    ocr::build(lines, OcrMode::Plain)
}

#[test]
fn ocr_빈_입력과_공백_조각은_빈_글() {
    assert_eq!(md(&[]), "");
    assert_eq!(plain(&[o("  ", 0.0)]), "");
}

#[test]
fn ocr_입력_순서와_상관없이_위에서_아래로_읽는다() {
    assert_eq!(plain(&[o("둘째", 1.0), o("첫째", 0.0), o("셋째", 2.0)]), "첫째\n둘째\n셋째");
}

#[test]
fn ocr_같은_높이의_조각은_왼쪽부터_한_줄로_합친다() {
    let lines = [oc("세계", 0.0, 0.5, 0.03), oc("안녕", 0.0, 0.1, 0.03), OcrLine::new("다음 줄", 0.1, 0.95 - 0.05, 0.3, 0.03)];
    // 세로 중심이 조금 어긋나도(줄 높이의 절반 이내) 같은 줄이다.
    let slanted = [OcrLine::new("왼쪽", 0.1, 0.80, 0.2, 0.03), OcrLine::new("오른쪽", 0.5, 0.805, 0.2, 0.03)];
    assert_eq!(md(&lines), "안녕 세계\n다음 줄");
    assert_eq!(plain(&slanted), "왼쪽 오른쪽");
}

#[test]
fn ocr_줄_간격이_중앙값의_1점6배를_넘으면_문단을_나눈다() {
    assert_eq!(plain(&[o("가", 0.0), o("나", 1.0), o("다", 3.0), o("라", 4.0)]), "가\n나\n\n다\n라");
    // 1.6배 이하의 간격은 같은 문단이다.
    assert_eq!(plain(&[o("가", 0.0), o("나", 1.0), o("다", 2.0), o("라", 3.5)]), "가\n나\n다\n라");
}

#[test]
fn ocr_줄_높이로_제목을_알아본다() {
    let lines = [oc("큰 제목", 0.0, 0.1, 0.05), o("본문 하나", 1.0), oc("중간 제목", 2.0, 0.1, 0.04), o("본문 둘", 3.0), o("본문 셋", 4.0)];
    let result = md(&lines);
    assert!(result.starts_with("# 큰 제목"), "{result}");
    assert!(result.contains("## 중간 제목"), "{result}");
    assert!(result.contains("\n본문 하나\n"), "{result}");
    // 텍스트만 모드는 제목 표시를 붙이지 않는다.
    assert!(!plain(&lines).contains('#'));
}

#[test]
fn ocr_모두_같은_높이면_제목이_없다() {
    assert_eq!(md(&[o("하나", 0.0), o("둘", 1.0)]), "하나\n둘");
}

#[test]
fn ocr_줄머리_기호는_글머리_목록으로() {
    let lines: Vec<OcrLine> = ["• 사과", "· 배", "▪ 귤", "◦ 감", "- 포도", "* 딸기"].iter().enumerate().map(|(i, t)| o(t, i as f64)).collect();
    assert_eq!(md(&lines), "- 사과\n- 배\n- 귤\n- 감\n- 포도\n- 딸기");
    // 공백 없는 하이픈은 글의 일부다.
    assert_eq!(md(&[o("-5도", 0.0)]), "-5도");
    // 텍스트만 모드는 기호를 그대로 둔다.
    assert_eq!(plain(&[o("• 사과", 0.0)]), "• 사과");
}

#[test]
fn ocr_번호는_1_꼴로() {
    let lines: Vec<OcrLine> = ["1. 하나", "2) 둘", "③ 셋", "⑩ 열"].iter().enumerate().map(|(i, t)| o(t, i as f64)).collect();
    assert_eq!(md(&lines), "1. 하나\n2. 둘\n3. 셋\n10. 열");
    // 소수나 금액은 번호가 아니다.
    assert_eq!(md(&[o("3.5달러", 0.0)]), "3.5달러");
}

#[test]
fn ocr_체크_기호는_체크리스트로() {
    let lines: Vec<OcrLine> = ["☐ 할 일", "□ 둘", "▢ 셋", "☑ 끝", "✓ 완료", "✔ 확인", "☒ 취소", "■ 네모"].iter().enumerate().map(|(i, t)| o(t, i as f64)).collect();
    assert_eq!(md(&lines), "- [ ] 할 일\n- [ ] 둘\n- [ ] 셋\n- [x] 끝\n- [x] 완료\n- [x] 확인\n- [x] 취소\n- [x] 네모");
}

#[test]
fn ocr_줄_높이의_1점5배_이상_안쪽에서_시작하는_목록은_두_칸_들인다() {
    let lines = [oc("• 위", 0.0, 0.1, 0.03), oc("• 아래", 1.0, 0.1 + 0.03 * 1.6, 0.03), oc("• 살짝", 2.0, 0.1 + 0.03 * 1.4, 0.03)];
    assert_eq!(md(&lines), "- 위\n  - 아래\n- 살짝");
    // 목록이 아닌 줄은 안쪽에서 시작해도 들이지 않는다.
    assert_eq!(md(&[oc("본문", 0.0, 0.1, 0.03), oc("들어간 글", 1.0, 0.4, 0.03)]), "본문\n들어간 글");
}

#[test]
fn ocr_제목_줄은_목록_기호가_있어도_제목으로_둔다() {
    let lines = [oc("1. 개요", 0.0, 0.1, 0.05), o("글", 1.0), o("글", 2.0)];
    assert!(md(&lines).starts_with("# 1. 개요"));
}

#[test]
fn h1_경로는_첨부_폴더의_파일_한_단계만_허용한다() {
    for path in ["attachments/.", "attachments/..", "attachments/", "attachments/a/b.png", "attachments/a\\b.png", "../a.png", "https://example.com/a.png"] {
        let source = format!("![설명]({path})");
        assert!(MarkdownImage::parse(&source).is_none(), "{source}");
        assert_eq!(round_trip(&source), source);
        assert_eq!(serialize(&parser::parse(&source), Flavor::Clipboard), source);
    }
    assert!(MarkdownImage::parse("![설명](attachments/a.png =120)").is_some());
}
