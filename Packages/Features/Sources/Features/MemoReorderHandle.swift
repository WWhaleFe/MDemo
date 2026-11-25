import AppKit
import MemoCore
import SwiftUI

/// 손잡이에서 시작한 이벤트만 받아 목록의 기본 여러 개 고르기를 보존한다.
struct MemoReorderHandle: NSViewRepresentable {
    var id: MemoID
    var hovered: Bool
    var begin: () -> Void
    var target: (MemoID, Bool) -> Void
    var finish: (Bool) -> Void
    var move: (Int) -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {
        view.id = id
        view.begin = begin
        view.target = target
        view.finish = finish
        view.move = move
        view.alphaValue = hovered ? 1 : 0.35
    }

    final class HandleView: NSView {
        var id: MemoID?
        var begin: (() -> Void)?
        var target: ((MemoID, Bool) -> Void)?
        var finish: ((Bool) -> Void)?
        var move: ((Int) -> Void)?
        private weak var trackingTable: NSTableView?
        private weak var trackingWindow: NSWindow?
        private var monitor: Any?
        private var timer: Timer?
        private var origin: NSPoint?
        private var dragging = false
        private var lastLocation = NSPoint.zero
        override var acceptsFirstResponder: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("순서 바꾸기")
            setAccessibilityHelp("손잡이를 끌거나 옵션 위아래 화살표로 순서를 바꿉니다")
        }
        required init?(coder: NSCoder) { fatalError("지원하지 않는 초기화") }
        /// 손잡이 그림은 라이트 · 다크마다 한 번만 만들어 모든 줄이 함께 쓴다.
        /// 줄마다 그릴 때마다 기호 그림을 새로 만들면 메모가 많을 때 목록 보기 전환이 눈에 띄게 느려진다.
        private static var imageCache: [Bool: NSImage] = [:]
        private static func handleImage(dark: Bool) -> NSImage? {
            if let cached = imageCache[dark] { return cached }
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)?
                .withSymbolConfiguration(.init(paletteColors: [NSColor(ListTheme.muted)]))
            imageCache[dark] = image
            return image
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let image = Self.handleImage(dark: dark)
            if window?.firstResponder === self {
                NSColor(ListTheme.ink).setStroke()
                let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 10), xRadius: 4, yRadius: 4)
                ring.lineWidth = 1.5
                ring.stroke()
            }
            image?.draw(in: NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14))
        }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
        override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            trackingTable = table
            trackingWindow = window
            origin = event.locationInWindow
            lastLocation = event.locationInWindow
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [self] event in
                if event.type == .keyDown {
                    if event.keyCode == 53 { stop(cancelled: true); return nil }
                    return event
                }
                lastLocation = event.locationInWindow
                if event.type == .leftMouseUp { stop(cancelled: false); return nil }
                if !dragging, let origin, hypot(lastLocation.x - origin.x, lastLocation.y - origin.y) >= 3 {
                    dragging = true
                    begin?()
                    NSCursor.closedHand.push()
                    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated { self?.updateDestination(scroll: true) }
                    }
                }
                if dragging { updateDestination(scroll: false) }
                return nil
            }
        }
        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.contains(.option), event.keyCode == 126 || event.keyCode == 125 {
                move?(event.keyCode == 126 ? -1 : 1)
            } else { super.keyDown(with: event) }
        }
        private var table: NSTableView? {
            var parent = superview
            while let view = parent {
                if let table = view as? NSTableView { return table }
                parent = view.superview
            }
            return trackingTable
        }
        private func handles(in view: NSView) -> [HandleView] {
            if let handle = view as? HandleView { return [handle] }
            return view.subviews.flatMap { handles(in: $0) }
        }
        private func updateDestination(scroll: Bool) {
            guard trackingWindow?.isVisible == true else { stop(cancelled: true); return }
            guard let table, let clip = table.enclosingScrollView?.contentView else { return }
            if scroll {
                let point = clip.convert(lastLocation, from: nil)
                let edge: CGFloat = 36
                var delta: CGFloat = 0
                if point.y < clip.bounds.minY + edge { delta = -10 }
                if point.y > clip.bounds.maxY - edge { delta = 10 }
                if delta != 0 {
                    let y = max(0, min(table.bounds.height - clip.bounds.height, clip.bounds.minY + delta))
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                    table.enclosingScrollView?.reflectScrolledClipView(clip)
                    table.layoutSubtreeIfNeeded()
                }
            }
            let point = table.convert(lastLocation, from: nil)
            let candidates = handles(in: table).filter { $0.id != nil && $0.convert($0.bounds, to: table).intersects(table.visibleRect) }
            guard let nearest = candidates.min(by: {
                abs($0.convert($0.bounds, to: table).midY - point.y) < abs($1.convert($1.bounds, to: table).midY - point.y)
            }), let id = nearest.id else { return }
            target?(id, point.y >= nearest.convert(nearest.bounds, to: table).midY)
        }
        private func stop(cancelled: Bool) {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            timer?.invalidate()
            timer = nil
            if dragging {
                NSCursor.pop()
                finish?(cancelled)
            }
            dragging = false
            origin = nil
        }
    }
}

/// 기본 선택의 파란 바탕과 흰 글자를 끄고 키보드·수정키 선택은 그대로 둔다.
struct ListSelectionAppearance: NSViewRepresentable {
    var onContext: () -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.onContext = onContext; view.configure() }
    final class Probe: NSView {
        var onContext: (() -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                    guard let self, event.window === window,
                          event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
                    var parent = superview
                    while let view = parent {
                        if let table = view as? NSTableView {
                            if table.row(at: table.convert(event.locationInWindow, from: nil)) == table.row(for: self) { onContext?() }
                            break
                        }
                        parent = view.superview
                    }
                    return event
                }
            }
            configure()
        }
        func configure() {
            DispatchQueue.main.async { [weak self] in
                var parent = self?.superview
                while let view = parent {
                    if let table = view as? NSTableView {
                        table.selectionHighlightStyle = .none
                        table.focusRingType = .none
                        return
                    }
                    parent = view.superview
                }
            }
        }
    }
}

struct MemoRowAppearance: ViewModifier {
    @Environment(\.controlActiveState) private var activeState
    var selected: Bool
    var dragging: Bool
    var contextTarget: Bool
    var onContext: () -> Void
    func body(content: Content) -> some View {
        content
            .foregroundStyle(ListTheme.ink)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8).fill(selected ? ListTheme.selectedRow.opacity(activeState == .inactive ? 0.7 : 1) : .clear)
                    .overlay(alignment: .leading) {
                        if selected { RoundedRectangle(cornerRadius: 1.5).fill(ListTheme.ink).frame(width: 3).padding(.vertical, 8) }
                    }.padding(.horizontal, 4)
            )
            .overlay {
                if contextTarget {
                    RoundedRectangle(cornerRadius: 8).stroke(ListTheme.ink, lineWidth: 1.5).padding(.horizontal, -12)
                        .allowsHitTesting(false)
                }
            }
            .background(ListSelectionAppearance(onContext: onContext).frame(width: 0, height: 0))
            .opacity(dragging ? 0.9 : 1)
            .background {
                if dragging {
                    RoundedRectangle(cornerRadius: 8).fill(ListTheme.card)
                        .shadow(color: ListTheme.ink.opacity(0.18), radius: 6, y: 3)
                }
            }
    }
}
