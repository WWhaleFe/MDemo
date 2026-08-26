import AppKit
import EditorKit
import MarkdownEngine
import TestKit

// 화면에 보이는 것과 파일에 저장되는 것이 서로 다르다는 점이 이 계층의 핵심 위험이다.
// 화면에는 "☐ 우유"가 보이지만 파일에는 "- [ ] 우유"가 들어가야 한다.
// 이 왕복이 깨지면 파일이 조용히 망가지므로 여기서 촘촘히 확인한다.

let runner = TestRunner("EditorKit")
let theme = EditorTheme(textColor: .black)

@MainActor
func makeTextView(loading markdown: String) -> MemoTextView {
    let textView = MemoTextView.makeTextKit1(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
    textView.loadMarkdown(markdown, theme: theme, textAlpha: 1.0)
    return textView
}

runner.test("마크다운을 열었다가 저장하면 원본 그대로다") { t in
    MainActor.assumeIsolated {
        let samples = [
            "# 제목",
            "## 소제목\n본문 문단",
            "- 사과\n- 배",
            "- [ ] 우유\n- [x] 계란",
            "1. 첫째\n2. 둘째",
            "**굵게** 그리고 *기울임*",
            "~~취소선~~과 ==형광==",
            "`코드` 조각",
            "> 인용문",
            "한글 **강조** 섞인 문장",
            "# 제목\n\n- [ ] 할 일\n\n마무리 문단",
        ]
        for sample in samples {
            let textView = makeTextView(loading: sample)
            t.expectEqual(textView.currentMarkdown(), sample, "왕복 실패")
        }
    }
}

runner.test("화면에는 기호 대신 표식이 보인다 (MD-01, MD-04)") { t in
    MainActor.assumeIsolated {
        let textView = makeTextView(loading: "# 제목\n- [ ] 우유\n- 사과")
        let visible = textView.string

        t.expect(!visible.contains("#"), "제목 기호가 화면에 남아 있다")
        t.expect(!visible.contains("- [ ]"), "체크박스 기호가 화면에 남아 있다")
        t.expect(visible.contains("☐"), "체크박스 표식이 없다")
        t.expect(visible.contains("•"), "글머리 표식이 없다")
        t.expect(visible.contains("제목"), "본문 글자가 사라졌다")
    }
}

runner.test("제목은 본문보다 크고 굵게 보인다 (TXT-05)") { t in
    MainActor.assumeIsolated {
        let textView = makeTextView(loading: "# 제목\n본문")
        guard let storage = textView.textStorage, storage.length > 0 else {
            t.expect(false, "텍스트가 비었다")
            return
        }
        let headingFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let bodyLocation = (textView.string as NSString).range(of: "본문").location
        let bodyFont = storage.attribute(.font, at: bodyLocation, effectiveRange: nil) as? NSFont

        t.expectNotNil(headingFont)
        t.expectNotNil(bodyFont)
        t.expect((headingFont?.pointSize ?? 0) > (bodyFont?.pointSize ?? 0), "제목이 본문보다 크지 않다")
    }
}

runner.test("빈 메모도 안전하게 열리고 저장된다") { t in
    MainActor.assumeIsolated {
        let textView = makeTextView(loading: "")
        t.expectEqual(textView.currentMarkdown(), "")
    }
}

runner.test("한글 조합 중에는 변환이 보류된다 (NFR-08)") { t in
    MainActor.assumeIsolated {
        let textView = makeTextView(loading: "")
        let controller = LiveFormatController(textView: textView, theme: theme, textAlpha: 1.0)

        // 조합 중 상태를 만든다 (한글 입력기가 미완성 글자를 올려둔 상태)
        textView.setMarkedText("ㄱ", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: 0, length: 0))
        t.expect(textView.isComposingText, "조합 상태를 만들지 못했다")

        let before = textView.string
        controller.textDidChange()
        t.expectEqual(textView.string, before, "조합 중에 텍스트가 바뀌었다 — 글자가 깨지는 원인")

        textView.unmarkText()
    }
}

runner.test("들여쓴 체크박스도 단계가 보존된다 (CHK-03)") { t in
    MainActor.assumeIsolated {
        let source = "- [ ] 상위\n  - [ ] 하위"
        let textView = makeTextView(loading: source)
        t.expectEqual(textView.currentMarkdown(), source, "들여쓰기 단계가 사라졌다")
    }
}

runner.finish()
