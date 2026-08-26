import Carbon.HIToolbox
import Foundation

/// 앱이 배경에 있어도 동작하는 단축키 (KEY-11, SYS-04).
///
/// 메뉴바에만 있는 앱이라 창을 찾아 누를 방법이 마땅치 않다.
/// 어디서 무엇을 하고 있든 손이 기억하는 키 하나로 메모를 띄울 수 있어야 쓸모가 있다.
///
/// 접근성 권한이 필요한 이벤트 탭 대신 Carbon 핫키를 쓴다.
/// 권한 요청 없이 등록할 수 있어 사용자를 번거롭게 하지 않는다.
public final class GlobalHotkeyService: @unchecked Sendable {
    public struct Shortcut: Hashable, Sendable {
        public var keyCode: UInt32
        public var modifiers: UInt32

        public init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        /// Cmd+Shift+N — 어디서든 새 메모 (KEY-11).
        public static let newMemo = Shortcut(
            keyCode: UInt32(kVK_ANSI_N),
            modifiers: UInt32(cmdKey | shiftKey)
        )

        /// Cmd+Shift+H — 모든 메모 보이기/숨기기 (SYS-04).
        public static let toggleAllMemos = Shortcut(
            keyCode: UInt32(kVK_ANSI_H),
            modifiers: UInt32(cmdKey | shiftKey)
        )

        public var displayText: String {
            var parts: [String] = []
            if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
            if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
            if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
            if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
            parts.append(Self.keyName(for: keyCode))
            return parts.joined()
        }

        private static func keyName(for keyCode: UInt32) -> String {
            switch Int(keyCode) {
            case kVK_ANSI_N: return "N"
            case kVK_ANSI_H: return "H"
            case kVK_ANSI_L: return "L"
            default: return "?"
            }
        }
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private let lock = NSLock()

    public init() {}

    deinit {
        unregisterAll()
    }

    /// 단축키를 등록한다. 이미 다른 앱이 쓰고 있으면 false.
    @discardableResult
    public func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        installEventHandlerIfNeeded()

        lock.lock()
        let id = nextID
        nextID += 1
        handlers[id] = action
        lock.unlock()

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            lock.lock()
            handlers.removeValue(forKey: id)
            lock.unlock()
            return false
        }

        lock.lock()
        hotKeyRefs[id] = reference
        lock.unlock()
        _ = hotKeyID
        return true
    }

    public func unregisterAll() {
        lock.lock()
        let references = hotKeyRefs
        hotKeyRefs.removeAll()
        handlers.removeAll()
        lock.unlock()

        for reference in references.values {
            UnregisterEventHotKey(reference)
        }
    }

    // MARK: - 이벤트 받기

    private static let signature: OSType = 0x4D454D4F  // 'MEMO'

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == GlobalHotkeyService.signature else { return noErr }

                let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                service.fire(id: hotKeyID.id)
                return noErr
            },
            1,
            &spec,
            context,
            &eventHandler
        )
    }

    private func fire(id: UInt32) {
        lock.lock()
        let action = handlers[id]
        lock.unlock()

        guard let action else { return }
        // 단축키는 어느 스레드에서 올지 알 수 없다. 화면 작업은 반드시 메인에서 한다.
        DispatchQueue.main.async(execute: action)
    }
}
