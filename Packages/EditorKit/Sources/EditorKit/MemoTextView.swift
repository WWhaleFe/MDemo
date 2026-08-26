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

    // MARK: - 목록 조작 훅
    //
    // 엔터·탭·클릭은 목록 문맥에 따라 동작이 달라진다.
    // 판단은 전부 LiveFormatController가 하고, 여기서는 그쪽으로 넘기기만 한다.

    /// 엔터. 목록을 이어가거나 빠져나온다. true를 돌려주면 기본 동작을 하지 않는다.
    public var onNewline: (() -> Bool)?
    /// Tab / Shift+Tab. 목록 들여쓰기 (KEY-08).
    public var onIndent: ((_ deeper: Bool) -> Bool)?
    /// 체크박스 표식 클릭 (CHK-01).
    public var onToggleCheckbox: ((_ characterIndex: Int) -> Bool)?
    /// 슬래시 팝업이 떠 있을 때 방향키·엔터를 먼저 가져간다 (SL-03).
    public var onKeyDown: ((NSEvent) -> Bool)?

    // MARK: - 빈 메모 안내
    //
    // 슬래시 명령이 있다는 것을 모르면 쓸 수가 없다.
    // 빈 메모에 한 줄 안내를 띄워 두는 것이 가장 확실한 안내다.

    /// 안내 문구는 별도의 라벨로 얹는다.
    ///
    /// 편집기의 `draw` 안에서 글자를 직접 그리면 텍스트 시스템이 그리는 도중에
    /// 또 다른 텍스트 그리기가 끼어든다. 그 상태에서 본문이 바뀌면 AppKit이 예외를 던져
    /// 앱이 그대로 종료된다. 그리기 경로를 아예 분리해 그런 겹침을 없앤다.
    private lazy var placeholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.textColor = NSColor.black.withAlphaComponent(0.28)
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        // 클릭이 라벨에 막히면 커서를 놓을 수 없다.
        label.refusesFirstResponder = true
        return label
    }()

    public var placeholderText: String = "" {
        didSet { updatePlaceholder() }
    }

    public var shouldShowPlaceholder: Bool {
        string.isEmpty && !placeholderText.isEmpty
    }

    public override func didChangeText() {
        super.didChangeText()
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        guard !placeholderText.isEmpty else {
            placeholderLabel.removeFromSuperview()
            return
        }

        placeholderLabel.stringValue = placeholderText
        placeholderLabel.font = font ?? NSFont.systemFont(ofSize: 14)
        placeholderLabel.sizeToFit()
        placeholderLabel.setFrameOrigin(
            NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height)
        )

        if shouldShowPlaceholder {
            if placeholderLabel.superview !== self {
                addSubview(placeholderLabel)
            }
        } else {
            placeholderLabel.removeFromSuperview()
        }
    }

    public override func keyDown(with event: NSEvent) {
        // 조합 중에 어떤 키까지 가져갈지는 팝업 쪽이 판단한다.
        // 여기서 일률적으로 막으면 "조합 중 엔터"가 조합 확정에만 쓰이고
        // 명령에는 닿지 않아, 엔터를 두 번 눌러야 하는 상황이 된다 (NFR-08).
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    /// 조합 중인 글자를 확정한다. 확정된 글자는 그대로 남는다.
    public func commitComposition() {
        guard hasMarkedText() else { return }
        unmarkText()
    }

    public override func insertNewline(_ sender: Any?) {
        if onNewline?() == true { return }
        super.insertNewline(sender)
    }

    public override func insertTab(_ sender: Any?) {
        if onIndent?(true) == true { return }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        if onIndent?(false) == true { return }
        super.insertBacktab(sender)
    }

    /// 편집 영역을 클릭했을 때 알린다. 떠 있는 팝업을 닫는 데 쓴다.
    public var onEditorClick: (() -> Void)?

    /// 체크박스 표식을 클릭하면 체크가 토글된다.
    /// 글자를 클릭한 경우에는 평소대로 커서만 옮긴다.
    public override func mouseDown(with event: NSEvent) {
        // 목록 바깥을 눌렀다는 뜻이므로 팝업부터 닫는다.
        onEditorClick?()

        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if onToggleCheckbox?(index) == true { return }
        super.mouseDown(with: event)
    }

    /// 지정한 위치가 속한 줄의 체크박스를 토글한다. 체크박스 줄이 아니면 false.
    @discardableResult
    public func toggleCheckbox(atCharacterIndex index: Int) -> Bool {
        onToggleCheckbox?(index) ?? false
    }

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
    public func resetTypingAttributes(theme: EditorTheme, textAlpha: Double, block: BlockStyle = .paragraph) {
        typingAttributes = [
            .font: theme.font(for: block),
            .foregroundColor: theme.textColor.withAlphaComponent(textAlpha),
            .memoBlockStyle: BlockStyleBox(block),
        ]
    }

    /// 글꼴이나 크기가 바뀌었을 때 이미 쓰인 내용에 새 설정을 다시 입힌다 (TXT-02, TXT-03).
    ///
    /// 내용을 마크다운으로 뽑아 다시 그리는 방식이라 서식이 어긋나지 않는다.
    public func reapplyTheme(_ theme: EditorTheme, textAlpha: Double) {
        let selection = selectedRange()
        let markdown = currentMarkdown()
        loadMarkdown(markdown, theme: theme, textAlpha: textAlpha)
        resetTypingAttributes(theme: theme, textAlpha: textAlpha)

        let length = (string as NSString).length
        setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }
}
