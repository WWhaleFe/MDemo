import AppKit

// Dock 아이콘 없이 메뉴바에만 상주한다 (SYS-01).
// Info.plist의 LSUIElement와 함께 동작하며, 여기서도 명시해 실행 방식에 관계없이 같게 만든다.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
