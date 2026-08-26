import AppKit
import MarkdownEngine
import MemoCore

/// 메모 본문 편집기.
///
/// M0 시점에는 순수 텍스트 편집만 한다. 실시간 마크다운 변환(MD-*)과 저장은 M1에서 붙인다.
/// 서식은 전부 텍스트 속성으로만 표현한다 — 서식마다 뷰를 만들면 메모리가 창 수에 곱해진다(§4-5).
public final class MemoTextView: NSTextView {
    /// 텍스트 알파를 뺀 기본 글자색. 알파는 이 색에 별도로 곱해 적용한다 (OPA-02).
    private var baseTextColor: NSColor = .labelColor
    private var currentTextAlpha: Double = 1.0

    /// TextKit 1 스택을 직접 구성해 만든다.
    ///
    /// 최신 macOS의 NSTextView는 기본으로 TextKit 2를 쓰지만,
    /// 한글 조합 중 속성 변경(NFR-08)에서 검증된 동작이 필요하므로 TextKit 1을 명시한다.
    /// 이 결정을 바꾸려면 여기 한 곳만 고치면 된다 (설계서 §1 기술 스택).
    public static func makeTextKit1(frame: NSRect) -> MemoTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        return MemoTextView(frame: frame, textContainer: container)
    }

    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("스토리보드를 사용하지 않는다")
    }

    private func configure() {
        drawsBackground = false            // 배경은 창 레이어가 그린다 (투명도 분리, OPA-01)
        isRichText = false                 // 저장 포맷은 마크다운이므로 RTF 붙여넣기를 막는다
        importsGraphics = false            // 이미지는 M5에서 첨부 파일로 처리한다 (IMG-07)
        isAutomaticQuoteSubstitutionEnabled = false   // 마크다운 기호가 변형되면 안 된다
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        allowsUndo = true
        textContainerInset = NSSize(width: 6, height: 8)
        font = .systemFont(ofSize: 13)
        applyTextAlpha(currentTextAlpha)
    }

    /// 텍스트 알파 적용 (OPA-02). 창 전체 알파(window.alphaValue)는 건드리지 않는다.
    public func applyTextAlpha(_ alpha: Double) {
        currentTextAlpha = MemoMeta.clampTextAlpha(alpha)
        let color = baseTextColor.withAlphaComponent(currentTextAlpha)
        textColor = color
        insertionPointColor = color
    }

    public func applyBaseTextColor(_ color: NSColor) {
        baseTextColor = color
        applyTextAlpha(currentTextAlpha)
    }

    /// 한글 조합 중인지 여부 (NFR-08).
    ///
    /// 실시간 변환은 이 값이 true인 동안 어떤 속성 변경도 하지 않고,
    /// 조합이 확정된 뒤에 검사한다. 조합 중 속성을 건드리면 글자가 깨진다.
    public var isComposingText: Bool { hasMarkedText() }

    // MARK: - 문서 싣고 꺼내기

    /// 마크다운을 읽어 화면에 서식으로 표시한다. 창을 열 때 한 번 호출한다.
    public func loadMarkdown(_ markdown: String, theme: EditorTheme, textAlpha: Double) {
        let lines = MarkdownParser.parse(markdown)
        let attributed = AttributedTextBridge.attributedString(from: lines, theme: theme, textAlpha: textAlpha)
        textStorage?.setAttributedString(attributed)
        // 파일을 여는 것은 사용자의 편집이 아니므로 되돌리기 이력에서 제외한다.
        undoManager?.removeAllActions()
    }

    /// 화면 내용을 표준 마크다운으로 되돌린다. 저장 직전에 호출한다 (DOC-01).
    public func currentMarkdown() -> String {
        guard let textStorage else { return string }
        return MarkdownSerializer.serialize(AttributedTextBridge.styledLines(from: textStorage))
    }

    /// 새로 입력하는 글자가 앞 글자의 서식을 물려받지 않게 한다.
    /// 제목 줄 끝에서 엔터를 치면 본문으로 돌아와야 한다 (TXT-05).
    public func resetTypingAttributes(theme: EditorTheme, textAlpha: Double) {
        typingAttributes = [
            .font: NSFont.systemFont(ofSize: theme.baseFontSize),
            .foregroundColor: theme.textColor.withAlphaComponent(textAlpha),
        ]
    }
}
