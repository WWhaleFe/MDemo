import AppKit

/// 화면에 보이지 않는 메인 메뉴. 편집 단축키(⌘C · ⌘V · ⌘X · ⌘A · ⌘Z)를 살리기 위해 둔다.
///
/// macOS는 이 단축키들을 앱의 메인 메뉴 → "편집" 메뉴를 거쳐 글자 칸에 전달한다.
/// 메뉴바 앱(LSUIElement)은 메인 메뉴를 보여 주지 않지만, 없으면 단축키도 통째로 사라진다 —
/// 메모 본문 · 제목 칸 · 목록 창 검색 칸에서 복사 · 붙여넣기가 먹지 않던 원인이다.
/// 각 항목의 target을 비워 두어, 그때 입력을 받고 있는 칸(first responder)이 처리하게 한다.
@MainActor
enum EditMenu {
    static func install() {
        let mainMenu = NSMenu()

        // 첫 메뉴는 앱 메뉴 자리다. 비워 두면 macOS가 두 번째 메뉴를 앱 메뉴로 잘못 쓴다.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "MDemo 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "편집")
        edit.addItem(NSMenuItem(title: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        let plainPaste = NSMenuItem(
            title: "서식 없이 붙여넣기",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            keyEquivalent: "v"
        )
        plainPaste.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(plainPaste)
        edit.addItem(NSMenuItem(title: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}
