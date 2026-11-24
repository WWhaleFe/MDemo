import AppKit
import SwiftUI

/// 편집 메뉴가 먼저 처리하는 키도 카드 화면에 전달한다. 검색 입력은 기본 동작을 유지한다
struct ListKeyboardCommands: NSViewRepresentable {
    let selectAll: () -> Void
    let delete: () -> Void
    let open: () -> Void
    var paste: (() -> Void)?
    var fit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.commands = self }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }

    @MainActor final class Coordinator {
        var commands: ListKeyboardCommands
        weak var view: NSView?
        var monitor: Any?
        init(_ commands: ListKeyboardCommands) { self.commands = commands }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = view?.window, event.window === window,
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return event }
                if event.modifierFlags.contains(.command) {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "a": commands.selectAll(); return nil
                    case "v": if let paste = commands.paste { paste(); return nil }
                    case "0": if let fit = commands.fit { fit(); return nil }
                    default: break
                    }
                } else if event.modifierFlags.intersection([.option, .control]).isEmpty {
                    switch event.keyCode {
                    case 51, 117: commands.delete(); return nil
                    case 36, 76: commands.open(); return nil
                    default: break
                    }
                }
                return event
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
