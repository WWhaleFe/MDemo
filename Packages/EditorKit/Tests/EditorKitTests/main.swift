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

/// 테스트가 끝날 때까지 컨트롤러를 붙잡아 둔다.
///
/// 엔터·탭·클릭 훅은 컨트롤러를 약하게 참조하므로, 컨트롤러가 해제되면 조용히 아무 일도 하지 않는다.
/// 앱에서는 창 컨트롤러가 들고 있지만 테스트에는 그런 주인이 없어 여기서 대신 잡아 준다.
@MainActor
enum ControllerKeeper {
    static var controllers: [LiveFormatController] = []
}

@MainActor
func makeEditor(loading markdown: String = "") -> (MemoTextView, LiveFormatController) {
    let textView = makeTextView(loading: markdown)
    let controller = LiveFormatController(textView: textView, theme: theme, textAlpha: 1.0)
    ControllerKeeper.controllers.append(controller)
    return (textView, controller)
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

// 사용자가 실제로 겪은 문제: `- `가 곧바로 글머리 목록이 되어 버려서
// 이어서 `[ ] `를 쳐도 체크박스가 만들어지지 않았다.
runner.test("타이핑 순서대로 체크박스가 만들어진다 (MD-04)") { t in
    MainActor.assumeIsolated {
        let textView = makeTextView(loading: "")
        let controller = LiveFormatController(textView: textView, theme: theme, textAlpha: 1.0)

        @MainActor func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
            controller.textDidChange()
        }

        type("- ")
        t.expect(textView.string.hasPrefix("• "), "글머리 목록이 되지 않았다: '\(textView.string)'")

        type("[ ] ")
        t.expect(textView.string.hasPrefix("☐ "), "체크박스로 바뀌지 않았다: '\(textView.string)'")

        type("우유")
        t.expectEqual(textView.currentMarkdown(), "- [ ] 우유", "저장 형식이 표준 마크다운이 아니다")
    }
}

// 사용자가 겪은 문제: 첫 줄에서 한 번 변환된 뒤로는 아무 변환도 일어나지 않는다.
runner.test("여러 줄을 이어 써도 줄마다 변환이 동작한다") { t in
    MainActor.assumeIsolated {
        let textView = makeTextView(loading: "")
        let controller = LiveFormatController(textView: textView, theme: theme, textAlpha: 1.0)

        @MainActor func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
            controller.textDidChange()
        }
        @MainActor func enter() {
            textView.insertNewline(nil)
            controller.textDidChange()
        }

        type("# 제목")
        enter()
        type("- 사과")
        enter()
        enter()
        type("**굵게**")

        t.expectEqual(textView.currentMarkdown(), "# 제목\n- 사과\n\n**굵게**", "둘째 줄부터 변환이 멈췄다")
    }
}

runner.test("목록에서 엔터를 치면 다음 항목이 이어진다 (노션 방식)") { t in
    MainActor.assumeIsolated {
        let textView = makeTextView(loading: "")
        let controller = LiveFormatController(textView: textView, theme: theme, textAlpha: 1.0)

        @MainActor func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
            controller.textDidChange()
        }
        @MainActor func enter() {
            textView.insertNewline(nil)
            controller.textDidChange()
        }

        type("- ")
        type("[ ] ")
        type("우유")
        enter()
        t.expect(textView.string.hasSuffix("☐ "), "다음 줄에 체크박스가 이어지지 않았다: '\(textView.string)'")

        type("계란")
        enter()
        // 빈 항목에서 엔터를 한 번 더 치면 목록을 빠져나온다
        enter()
        type("마무리")

        t.expectEqual(textView.currentMarkdown(), "- [ ] 우유\n- [ ] 계란\n마무리")
    }
}

runner.test("번호 목록은 엔터마다 번호가 올라간다 (MD-03)") { t in
    MainActor.assumeIsolated {
        let (textView, controller) = makeEditor()

        @MainActor func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
            controller.textDidChange()
        }

        // 실제 입력처럼 기호를 먼저 치고 내용을 이어 친다.
        type("1. ")
        type("첫째")
        textView.insertNewline(nil); controller.textDidChange()
        type("둘째")

        t.expectEqual(textView.currentMarkdown(), "1. 첫째\n2. 둘째")
    }
}

runner.test("체크박스를 클릭하면 체크가 토글된다 (CHK-01)") { t in
    MainActor.assumeIsolated {
        let (textView, _) = makeEditor(loading: "- [ ] 우유\n- [x] 계란")

        t.expect(textView.toggleCheckbox(atCharacterIndex: 0), "첫 줄 체크박스 토글 실패")
        t.expectEqual(textView.currentMarkdown(), "- [x] 우유\n- [x] 계란")

        let secondLineStart = (textView.string as NSString).range(of: "계란").location - 2
        t.expect(textView.toggleCheckbox(atCharacterIndex: secondLineStart), "둘째 줄 체크박스 토글 실패")
        t.expectEqual(textView.currentMarkdown(), "- [x] 우유\n- [ ] 계란")
    }
}

runner.test("글자를 클릭하면 체크가 바뀌지 않는다") { t in
    MainActor.assumeIsolated {
        let (textView, _) = makeEditor(loading: "- [ ] 우유")
        let textIndex = (textView.string as NSString).range(of: "우유").location + 1
        t.expect(!textView.toggleCheckbox(atCharacterIndex: textIndex), "글자 클릭인데 체크가 토글됐다")
        t.expectEqual(textView.currentMarkdown(), "- [ ] 우유")
    }
}

runner.test("Tab으로 목록을 들여쓰고 Shift+Tab으로 되돌린다 (KEY-08)") { t in
    MainActor.assumeIsolated {
        let (textView, _) = makeEditor(loading: "- [ ] 우유")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        textView.insertTab(nil)
        t.expectEqual(textView.currentMarkdown(), "  - [ ] 우유", "들여쓰기가 되지 않았다")

        textView.insertBacktab(nil)
        t.expectEqual(textView.currentMarkdown(), "- [ ] 우유", "내어쓰기가 되지 않았다")
    }
}

// 사용자가 겪은 문제: 슬래시 명령을 몇 번 쓰고 나면 타자가 아예 먹히지 않았다.
// 팝업이 입력 포커스를 가져간 뒤 돌려주지 않는 것이 원인이었다.
runner.test("슬래시 팝업을 여러 번 써도 편집기가 입력 포커스를 유지한다") { t in
    MainActor.assumeIsolated {
        let (textView, controller) = makeEditor()

        // 실제 창에 넣어야 포커스 이동을 확인할 수 있다.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let container = NSView(frame: window.contentLayoutRect)
        container.addSubview(textView)
        window.contentView = container
        window.makeFirstResponder(textView)
        t.expect(window.firstResponder === textView, "시작부터 편집기가 포커스를 갖지 못했다")

        @MainActor func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
            controller.textDidChange()
        }

        // 슬래시 명령을 세 번 반복한다.
        for round in 1...3 {
            type("/체크")
            controller.applySlashCommand(SlashCommandCatalog.filter("체크")[0])
            type("항목\(round)")
            textView.insertNewline(nil)
            controller.textDidChange()

            t.expect(
                window.firstResponder === textView,
                "\(round)번째 슬래시 명령 뒤 편집기가 포커스를 잃었다 — 타자가 먹통이 되는 상태"
            )
        }

        controller.dismissPopups()
        t.expect(window.firstResponder === textView, "팝업을 닫은 뒤 포커스가 돌아오지 않았다")
        t.expect(textView.currentMarkdown().contains("- [ ] 항목1"), "슬래시 명령이 체크박스를 만들지 못했다")
    }
}

// 사용자가 "무슨 명령이 있는지 알 수 없다"고 한 지점.
// 슬래시 하나만 쳐도 전체 목록이 보여야 무엇을 쓸 수 있는지 알 수 있다.
runner.test("슬래시 하나만 쳐도 전체 명령 목록이 보인다 (SL-01)") { t in
    MainActor.assumeIsolated {
        let (textView, controller) = makeEditor()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let container = NSView(frame: window.contentLayoutRect)
        container.addSubview(textView)
        window.contentView = container
        window.makeFirstResponder(textView)

        textView.insertText("/", replacementRange: textView.selectedRange())
        controller.textDidChange()

        t.expect(controller.isSlashPopupVisible, "슬래시만 쳤는데 목록이 뜨지 않았다")
        t.expectEqual(controller.visibleSlashCommands.count, SlashCommandCatalog.standard.count, "전체 명령이 보여야 한다")

        // 이어 입력하면 좁혀진다 (SL-02)
        textView.insertText("체크", replacementRange: textView.selectedRange())
        controller.textDidChange()
        t.expect(controller.visibleSlashCommands.first?.id == "checkbox", "이어 입력했을 때 좁혀지지 않았다")

        controller.dismissPopups()
    }
}

// 사용자가 겪은 문제: 슬래시 뒤에 한글 키워드를 치면 앱이 잠깐 멈추거나 입력이 안 됐다.
// 조합 중에도 목록은 따라와야 하고, 글자를 고치는 일은 하지 않아야 한다.
runner.test("한글 조합 중에도 드롭다운이 따라오되 글자는 건드리지 않는다 (NFR-08)") { t in
    MainActor.assumeIsolated {
        let (textView, controller) = makeEditor()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let container = NSView(frame: window.contentLayoutRect)
        container.addSubview(textView)
        window.contentView = container
        window.makeFirstResponder(textView)

        textView.insertText("/", replacementRange: textView.selectedRange())
        controller.textDidChange()
        t.expectEqual(controller.visibleSlashCommands.count, SlashCommandCatalog.standard.count)

        // 한글 입력기가 미완성 글자를 올려둔 상태를 만든다.
        let markedRange = NSRange(location: textView.selectedRange().location, length: 0)
        textView.setMarkedText("ㅊ", selectedRange: NSRange(location: 0, length: 1), replacementRange: markedRange)
        t.expect(textView.isComposingText, "조합 상태를 만들지 못했다")

        let before = textView.string
        controller.textDidChange()
        t.expectEqual(textView.string, before, "조합 중에 글자가 바뀌었다 — 입력이 깨지는 원인")
        t.expect(controller.isSlashPopupVisible, "조합 중이라고 목록이 사라지면 한글로 키워드를 칠 수 없다")

        textView.unmarkText()
        controller.dismissPopups()
    }
}

runner.test("드롭다운은 입력한 키워드를 그대로 기억해 보여 준다 (SL-02)") { t in
    MainActor.assumeIsolated {
        let (textView, controller) = makeEditor()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let container = NSView(frame: window.contentLayoutRect)
        container.addSubview(textView)
        window.contentView = container
        window.makeFirstResponder(textView)

        textView.insertText("/todo", replacementRange: textView.selectedRange())
        controller.textDidChange()

        // 제목에 없는 키워드로도 찾아진다는 것이 핵심이다.
        t.expect(controller.visibleSlashCommands.first?.id == "checkbox", "키워드로 검색되지 않았다")
        t.expect(
            controller.visibleSlashCommands.first?.keywords.contains("todo") == true,
            "찾은 명령이 그 키워드를 갖고 있어야 목록에 표시할 수 있다"
        )
        controller.dismissPopups()
    }
}

@MainActor
func makeKeyEvent(keyCode: UInt16, characters: String) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )
}

@MainActor
func makeWindowedEditor(loading markdown: String = "") -> (MemoTextView, LiveFormatController, NSWindow) {
    let (textView, controller) = makeEditor(loading: markdown)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    let container = NSView(frame: window.contentLayoutRect)
    container.addSubview(textView)
    window.contentView = container
    window.makeFirstResponder(textView)
    return (textView, controller, window)
}

// 사용자가 겪은 문제: `/키워드` 뒤 엔터를 눌러도 서식이 적용되지 않았다.
runner.test("키워드를 친 뒤 엔터를 누르면 서식이 적용된다 (SL-03)") { t in
    MainActor.assumeIsolated {
        let (textView, controller, _) = makeWindowedEditor()

        textView.insertText("/todo", replacementRange: textView.selectedRange())
        controller.textDidChange()
        t.expect(controller.isSlashPopupVisible, "팝업이 뜨지 않아 확인할 수 없다")

        guard let enter = makeKeyEvent(keyCode: 36, characters: "\r") else {
            t.expect(false, "키 이벤트를 만들지 못했다")
            return
        }
        textView.keyDown(with: enter)

        t.expect(textView.string.hasPrefix("☐ "), "체크박스가 적용되지 않았다: '\(textView.string)'")
        t.expect(!textView.string.contains("/todo"), "입력한 명령 글자가 남아 있다")
        t.expect(!controller.isSlashPopupVisible, "적용 후에도 팝업이 남아 있다")
    }
}

// 한글은 마지막 글자가 조합 중인 상태로 엔터를 누르게 된다.
// 그대로 두면 엔터가 조합 확정에만 쓰여 명령이 적용되지 않는다.
runner.test("한글 키워드 조합 중에 엔터를 눌러도 한 번에 적용된다 (NFR-08, SL-03)") { t in
    MainActor.assumeIsolated {
        let (textView, controller, _) = makeWindowedEditor()

        textView.insertText("/", replacementRange: textView.selectedRange())
        controller.textDidChange()

        // "체크"를 입력하되 마지막 글자가 아직 조합 중인 상태를 만든다.
        let caret = textView.selectedRange()
        textView.setMarkedText(
            "체크",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: caret.location, length: 0)
        )
        controller.textDidChange()
        t.expect(textView.isComposingText, "조합 상태를 만들지 못했다")
        t.expect(controller.visibleSlashCommands.first?.id == "checkbox", "조합 중 키워드로 걸러지지 않았다")

        guard let enter = makeKeyEvent(keyCode: 36, characters: "\r") else {
            t.expect(false, "키 이벤트를 만들지 못했다")
            return
        }
        textView.keyDown(with: enter)

        t.expect(!textView.isComposingText, "조합이 확정되지 않았다")
        t.expect(textView.string.hasPrefix("☐ "), "엔터 한 번에 적용되지 않았다: '\(textView.string)'")
    }
}

runner.test("메모 영역을 클릭하면 드롭다운이 닫힌다") { t in
    MainActor.assumeIsolated {
        let (textView, controller) = makeEditor()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let container = NSView(frame: window.contentLayoutRect)
        container.addSubview(textView)
        window.contentView = container
        window.makeFirstResponder(textView)

        textView.insertText("/", replacementRange: textView.selectedRange())
        controller.textDidChange()
        t.expect(controller.isSlashPopupVisible, "팝업이 뜨지 않아 확인할 수 없다")

        // 편집 영역 클릭 = 목록 바깥을 누른 것
        textView.onEditorClick?()
        t.expect(!controller.isSlashPopupVisible, "메모를 클릭했는데 팝업이 남아 있다")
    }
}

runner.test("빈 메모에는 슬래시 안내 문구가 보인다") { t in
    MainActor.assumeIsolated {
        let (textView, _) = makeEditor()
        textView.placeholderText = "/ 를 입력하면 서식 목록이 열립니다"

        t.expect(textView.shouldShowPlaceholder, "빈 메모인데 안내가 보이지 않는다")

        textView.insertText("내용", replacementRange: textView.selectedRange())
        t.expect(!textView.shouldShowPlaceholder, "내용을 쓰면 안내가 사라져야 한다")
    }
}

runner.test("대괄호만 쳐도 체크박스가 만들어진다") { t in
    MainActor.assumeIsolated {
        let (textView, controller) = makeEditor()

        @MainActor func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
            controller.textDidChange()
        }

        type("[] ")
        t.expect(textView.string.hasPrefix("☐ "), "[] 로 체크박스가 만들어지지 않았다: '\(textView.string)'")

        type("우유")
        t.expectEqual(textView.currentMarkdown(), "- [ ] 우유")
    }
}

runner.test("대괄호 안에 공백을 넣은 형태도 인식한다") { t in
    MainActor.assumeIsolated {
        let (textView, controller) = makeEditor()
        textView.insertText("[ ] ", replacementRange: textView.selectedRange())
        controller.textDidChange()
        t.expect(textView.string.hasPrefix("☐ "), "[ ] 로 체크박스가 만들어지지 않았다: '\(textView.string)'")
    }
}

runner.test("글꼴과 크기 설정이 실제로 반영된다 (TXT-02, TXT-03)") { t in
    MainActor.assumeIsolated {
        let large = EditorTheme(fontFamily: FontResolver.defaultFamily(), baseFontSize: 20, textColor: .black)
        let textView = MemoTextView.makeTextKit1(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        textView.loadMarkdown("본문", theme: large, textAlpha: 1.0)

        let font = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        t.expectEqual(font?.pointSize, 20, "글자 크기 설정이 반영되지 않았다")

        // 크기를 바꾸면 이미 쓴 내용에도 적용된다
        textView.reapplyTheme(EditorTheme(baseFontSize: 11), textAlpha: 1.0)
        let resized = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        t.expectEqual(resized?.pointSize, 11, "설정 변경이 기존 내용에 반영되지 않았다")
        t.expectEqual(textView.currentMarkdown(), "본문", "테마를 바꾸는 사이 내용이 변했다")
    }
}

runner.test("화면 밀도에 맞는 크기를 계산한다 (SET-01, TXT-03)") { t in
    MainActor.assumeIsolated {
        let recommendation = DisplayMetrics.recommended()

        t.expect(EditorTheme.fontSizeSteps.contains(recommendation.fontSize), "정해진 크기 단계를 벗어났다")
        t.expect(recommendation.scale >= 1.0 && recommendation.scale <= 2.0, "배율이 제한 범위를 벗어났다")

        // 촘촘한 화면일수록 글자가 커져야 물리적으로 같은 크기로 보인다.
        if recommendation.pointsPerInch > DisplayMetrics.referencePointsPerInch * 1.3 {
            t.expect(recommendation.fontSize > 14, "고밀도 화면인데 글자가 커지지 않았다")
        }

        // 창이 화면을 뒤덮으면 스티키 노트가 아니다.
        if let visible = NSScreen.main?.visibleFrame {
            t.expect(recommendation.memoSize.width <= visible.width * 0.4 + 1, "창이 너무 넓다")
            t.expect(recommendation.memoSize.height <= visible.height * 0.6 + 1, "창이 너무 높다")
        }
    }
}

runner.test("기본 글꼴은 맑은 고딕이거나 그 대체 글꼴이다") { t in
    MainActor.assumeIsolated {
        let family = FontResolver.defaultFamily()
        t.expectNotNil(family, "쓸 수 있는 한글 글꼴이 하나도 없다")
        t.expect(FontResolver.preferredFamilies.contains(family ?? ""), "권장 목록 밖의 글꼴이 선택됐다")
        // 설치되지 않은 글꼴을 지정해도 안전하게 대체돼야 한다
        let fallback = FontResolver.font(family: "존재하지않는글꼴", size: 15)
        t.expect(fallback.pointSize == 15, "대체 글꼴 크기가 어긋났다")
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
