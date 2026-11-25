import AppKit
import MarkdownEngine

/// 이미지 줄의 글자 자리를 차지하는 첨부 (IMG-01).
///
/// 줄에는 이 첨부 글자(U+FFFC) 하나만 있다. 마크다운 원문 `![alt](경로 =너비)`은 `reference`에 들어 있고
/// 저장할 때 `MarkdownSerializer`가 되살린다. 그림은 표시할 때마다 `MemoImageStore`의 썸네일을 그린다.
///
/// 그림 자체를 속성에 붙들지 않는다. 첨부가 이미지를 들고 있으면 창마다 원본 크기만큼 메모리가 늘기 때문이다.
public final class MemoImageAttachment: NSTextAttachment {
    /// 줄 안의 사실상의 원문. 크기를 끌어 바꾸면 이 값의 너비가 바뀐다.
    public var reference: MarkdownImage

    /// 끄는 동안에는 마지막 썸네일만 늘려 그리고, 놓은 뒤 새 크기로 읽는다.
    var isResizing = false
    private var resizeThumbnail: NSImage?

    func beginResizing(thumbnail: NSImage?) {
        resizeThumbnail = thumbnail
        isResizing = true
    }

    func endResizing() {
        isResizing = false
        resizeThumbnail = nil
    }

    /// 이미지를 못 찾았을 때 자리를 잡아 둘 크기.
    private static let missingSize = NSSize(width: 180, height: 56)
    /// 첨부 바닥을 기준선보다 내려 놓는 거리. 영역 계산에서 같은 값을 쓴다.
    static let baselineDrop: CGFloat = 4
    /// 너무 작아져 손잡이를 잡을 수 없게 되는 것을 막는 하한.
    public static let minimumWidth: CGFloat = 32

    public init(reference: MarkdownImage) {
        self.reference = reference
        super.init(data: nil, ofType: nil)
        // 기본 첨부 그림(파일 아이콘)이 끼어들지 않게 아주 작은 빈 그림을 달아 둔다.
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("스토리보드를 사용하지 않는다")
    }

    /// 줄 폭 안에서 실제로 그릴 크기. 지정 너비가 없으면 원본 크기, 어느 쪽이든 줄 폭을 넘지 않는다.
    func displaySize(natural: NSSize?, availableWidth: CGFloat) -> NSSize {
        guard let natural, natural.width > 0, natural.height > 0 else { return Self.missingSize }
        let limit = max(Self.minimumWidth, availableWidth)
        let requested = reference.width.map(CGFloat.init) ?? natural.width
        let width = min(max(Self.minimumWidth, requested), limit)
        return NSSize(width: width, height: (width * natural.height / natural.width).rounded())
    }

    // MARK: - 텍스트 시스템에서 부르는 곳

    public override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let padding = textContainer?.lineFragmentPadding ?? 5
        let viewportWidth = textContainer?.textView.map { view in
            MainActor.assumeIsolated { view.bounds.width - view.textContainerInset.width * 2 }
        }
        let lineWidth = textContainer?.widthTracksTextView == false ? (viewportWidth ?? 400) : lineFrag.width
        let available = min(4096, lineWidth - padding * 2)
        let store = Self.store(for: textContainer)
        let size = displaySize(natural: store?.naturalSize(of: reference.fileName), availableWidth: available)
        // 바닥을 기준선보다 조금 내려 다음 줄과 겹치지 않게 간격을 둔다.
        return NSRect(x: 0, y: -Self.baselineDrop, width: size.width, height: size.height)
    }

    public override func image(
        forBounds imageBounds: NSRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> NSImage? {
        let store = Self.store(for: textContainer)
        let scale = Self.scale(for: textContainer)
        let thumbnail = isResizing ? resizeThumbnail
            : store?.thumbnail(of: reference.fileName, displayWidth: imageBounds.width, scale: scale)
        if let thumbnail, let rendered = thumbnail.copy() as? NSImage {
            // 공유 캐시는 바꾸지 않고 그리기용 복사본의 크기만 바꾼다.
            rendered.size = imageBounds.size
            return rendered
        }
        return Self.missingImage(size: imageBounds.size, name: reference.fileName)
    }

    private static func store(for textContainer: NSTextContainer?) -> MemoImageStore? {
        guard let textView = textContainer?.textView else { return nil }
        return MainActor.assumeIsolated { (textView as? MemoTextView)?.imageStore }
    }

    private static func scale(for textContainer: NSTextContainer?) -> CGFloat {
        guard let textView = textContainer?.textView else { return 2 }
        return MainActor.assumeIsolated { textView.window?.backingScaleFactor ?? 2 }
    }

    /// 파일이 없을 때 보이는 자리표시.
    private static func missingImage(size: NSSize, name: String) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.5, alpha: 0.15).setFill()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            path.fill()
            NSColor(white: 0.3, alpha: 0.4).setStroke()
            path.lineWidth = 1
            path.stroke()
            let text = "이미지를 찾을 수 없음\n\(name)" as NSString
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(white: 0.25, alpha: 0.8),
                .paragraphStyle: style,
            ]
            let height = text.size(withAttributes: attributes).height
            text.draw(in: NSRect(x: 4, y: (rect.height - height) / 2, width: rect.width - 8, height: height + 2), withAttributes: attributes)
            return true
        }
    }
}
