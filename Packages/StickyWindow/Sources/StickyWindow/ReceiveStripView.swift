import AppKit

/// 메모 창 맨 위 줄 바로 아래에 끼는 AirDrop 받기 띠.
/// "iPhone에서 사진을 보내 주세요" · 진행 막대 · 남은 시간 · 멈추기 기호.
@MainActor
final class ReceiveStripView: NSView {
    static let height: CGFloat = 30

    var onStop: (() -> Void)?

    private let label = NSTextField(labelWithString: "iPhone에서 사진을 보내 주세요")
    private let track = NSView()
    private let fill = NSView()
    private let timeLabel = NSTextField(labelWithString: "2:00")
    private let stopButton = NSButton()
    private var fillWidth: NSLayoutConstraint?
    private let ink = NSColor(srgbRed: 28 / 255, green: 29 / 255, blue: 32 / 255, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        isHidden = true

        label.font = .systemFont(ofSize: 12)
        label.textColor = ink
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        track.wantsLayer = true
        track.layer?.backgroundColor = ink.withAlphaComponent(0.12).cgColor
        track.layer?.cornerRadius = 1.5
        fill.wantsLayer = true
        fill.layer?.backgroundColor = ink.cgColor
        fill.layer?.cornerRadius = 1.5

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = NSColor(srgbRed: 91 / 255, green: 94 / 255, blue: 102 / 255, alpha: 1)

        stopButton.title = ""
        stopButton.isBordered = false
        stopButton.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "받기 멈추기")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        stopButton.imagePosition = .imageOnly
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stopButton.widthAnchor.constraint(equalToConstant: 26),
            stopButton.heightAnchor.constraint(equalToConstant: 26),
        ])
        stopButton.contentTintColor = ink
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.toolTip = "받기 멈추기"
        stopButton.setAccessibilityLabel("받기 멈추기")

        track.translatesAutoresizingMaskIntoConstraints = false
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        let row = NSStackView(views: [label, track, timeLabel, stopButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        addSubview(row)

        let width = fill.widthAnchor.constraint(equalToConstant: 0)
        fillWidth = width
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            track.heightAnchor.constraint(equalToConstant: 3),
            track.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            width,
        ])
        // 막대가 남는 폭을 차지한다.
        track.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("스토리보드를 사용하지 않는다") }

    override func layout() {
        super.layout()
        updateFill()
    }

    private var progress: Double = 0

    /// - Parameters:
    ///   - remaining: 남은 초.
    ///   - total: 전체 초.
    ///   - received: 지금까지 받은 장수.
    func update(remaining: Int, total: Int, received: Int) {
        label.stringValue = received > 0 ? "사진 \(received)장 받음" : "iPhone에서 사진을 보내 주세요"
        timeLabel.stringValue = Self.timeText(remaining)
        progress = total > 0 ? min(1, max(0, 1 - Double(remaining) / Double(total))) : 0
        updateFill()
    }

    private func updateFill() {
        fillWidth?.constant = track.bounds.width * progress
    }

    /// m:ss 꼴의 남은 시간.
    static func timeText(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    @objc private func stopTapped() { onStop?() }
}

/// 메모 창과 따로 뜨는 작은 보조 창(글자 읽기 · 내보내기). 닫히면 정리 동작을 한다.
@MainActor
final class AuxiliaryWindow: NSObject, NSWindowDelegate {
    let window: NSPanel
    var onClose: (() -> Void)?

    init(title: String, contentSize: NSSize, content: NSView) {
        window = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.contentView = content
        window.delegate = self
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        let handler = onClose
        onClose = nil
        window.delegate = nil
        handler?()
    }
}
