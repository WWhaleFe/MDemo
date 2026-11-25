import AppKit
import EditorKit
import MemoCore

@MainActor
final class PasswordFields: NSObject, NSTextFieldDelegate {
    let password = NSSecureTextField()
    let confirmation = NSSecureTextField()
    let count = NSTextField(labelWithString: "0/6")
    private let formatter = PasswordInputFormatter()
    var changed: (() -> Void)?
    override init() {
        super.init()
        for field in [password, confirmation] {
            field.formatter = formatter
            field.delegate = self
            field.placeholderString = field === password ? "암호" : "한 번 더"
            field.setAccessibilityLabel(field.placeholderString)
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        for field in [password, confirmation] {
            let filtered = LockCrypto.filteredPassword(field.stringValue)
            if field.stringValue != filtered { field.stringValue = filtered }
        }
        count.stringValue = "\(password.stringValue.count)/6"
        changed?()
    }
    func clear() { password.stringValue = ""; confirmation.stringValue = "" }
}

@MainActor
public enum MemoLockDialogs {
    public enum Warning { case create, moveToLocked, moveToPlain }

    public static func password(title: String) -> String? {
        let fields = PasswordFields()
        defer { fields.clear(); fields.changed = nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "4~6자, 영문 대소문자와 숫자"
        alert.addButton(withTitle: "암호 설정")
        alert.addButton(withTitle: "취소")
        let stack = NSStackView(views: [fields.password, fields.count, fields.confirmation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 95)
        fields.password.widthAnchor.constraint(equalToConstant: 360).isActive = true
        fields.confirmation.widthAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = stack
        alert.buttons[0].isEnabled = false
        fields.changed = {
            alert.buttons[0].isEnabled = LockCrypto.validPassword(fields.password.stringValue)
                && LockCrypto.constantTimeEqual(fields.password.stringValue, fields.confirmation.stringValue)
        }
        alert.window.initialFirstResponder = fields.password
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return fields.password.stringValue
    }

    public static func confirm(_ kind: Warning) -> Bool {
        let title: String
        let rows: [String]
        let action: String
        switch kind {
        case .create:
            title = "암호 메모는 이렇게 지켜집니다"
            rows = [
                "이 메모는 **처음부터 암호화되어** 저장됩니다. 암호와 열쇠는 어디에도 저장되지 않고, 열쇠는 이 맥 키체인에만 암호로 잠겨 보관됩니다.",
                "이 메모는 **이 맥에만** 있습니다. iCloud 동기화·다른 맥·iPhone 읽기용 사본·Time Machine·MDemo 백업에 들어가지 않습니다.",
                "목록에는 **제목만** 보이고, 본문 검색·복제·이미지로 내보내기·노션 복사는 할 수 없습니다.",
                "창을 닫거나 내리면, 맥이 잠자거나 화면이 잠기면 **다시 잠깁니다**.",
                "**암호를 잊으면** 누구도, MDemo도 되살릴 수 없습니다. 맥을 새로 설치하거나 키체인을 잃어도 열 수 없습니다.",
                "암호를 **10번 틀리면** 이 메모는 **영구 삭제**되고 복구할 수 없습니다."]
            action = "이해했고 만들기"
        case .moveToLocked:
            title = "암호 메모로 옮기면 이렇게 됩니다"
            rows = [
                "**새 암호 메모**를 만들어 지금 내용과 사진을 암호화해 옮깁니다. 제목·색·그룹은 그대로, 파이프 연결과 보드 자리는 옮기지 않습니다.",
                "옮긴 뒤 **원래 메모는 이 맥·iCloud·다른 맥에서 영구 삭제**됩니다. 휴지통에 남지 않고 되돌릴 수 없습니다.",
                "원래 메모의 **예전 내용**은 Time Machine, 예전 백업 ZIP, iCloud '최근 삭제된 항목', 내보낸 이미지에 남아 있을 수 있습니다. 완전히 지우려면 그 백업을 직접 정리해 주세요.",
                "새 암호 메모는 **이 맥에만** 있고 동기화·백업에 들어가지 않습니다.",
                "**암호를 잊으면** 되살릴 수 없고, **10번 틀리면** 영구 삭제됩니다."]
            action = "이해했고 옮기기"
        case .moveToPlain:
            title = "일반 메모로 옮기면 이렇게 됩니다"
            rows = ["새 일반 메모를 만들어 내용을 옮기고, 암호 메모는 열쇠까지 지워 영구 삭제합니다.",
                    "새 일반 메모는 다시 iCloud로 동기화되고 백업에 들어갑니다."]
            action = "옮기기"
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "경고")
        alert.addButton(withTitle: action)
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: "취소")
        let list = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            list.append(NSAttributedString(string: "\(index + 1). ", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
            for (part, text) in row.components(separatedBy: "**").enumerated() {
                list.append(NSAttributedString(string: text, attributes: [.font: part % 2 == 0 ? NSFont.systemFont(ofSize: 13) : NSFont.boldSystemFont(ofSize: 13)]))
            }
            list.append(NSAttributedString(string: "\n\n"))
        }
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = list
        // 420pt 창 안에서 좌우 여백을 제외한 폭으로 줄바꿈한다.
        label.preferredMaxLayoutWidth = 380
        label.widthAnchor.constraint(equalToConstant: 380).isActive = true
        let checkbox = NSButton(checkboxWithTitle: "이해했습니다", target: nil, action: nil)
        checkbox.setAccessibilityLabel("이해했습니다")
        let gate = ConfirmationGate()
        gate.changed = { alert.buttons[0].isEnabled = checkbox.state == .on }
        checkbox.target = gate
        checkbox.action = #selector(ConfirmationGate.toggle)
        let needsCheck = kind != .moveToPlain
        let stack = NSStackView(views: needsCheck ? [label, checkbox] : [label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setFrameSize(NSSize(width: 380, height: label.fittingSize.height + (needsCheck ? 32 : 0)))
        alert.accessoryView = stack
        alert.buttons[0].isEnabled = !needsCheck
        return withExtendedLifetime(gate) { alert.runModal() == .alertFirstButtonReturn }
    }

    public static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "암호 메모 작업을 마치지 못했습니다"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

@MainActor
private final class ConfirmationGate: NSObject {
    var changed: (() -> Void)?
    @objc func toggle() { changed?() }
}

@MainActor
final class MemoLockView: NSView {
    let fields = PasswordFields()
    let message = NSTextField(wrappingLabelWithString: "잠긴 메모입니다")
    let button = NSButton(title: "열기", target: nil, action: nil)
    let progress = NSProgressIndicator()
    var open: ((String) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        // 메모 종이는 화면 모드와 상관없이 늘 밝은 색이다. 다크 모드의 흰 글자가 종이 위에서 사라지지 않게
        // 잠금 화면은 밝은 모양으로 그리고, 글자는 제목과 같은 먹색을 쓴다.
        appearance = NSAppearance(named: .aqua)
        let ink = NSColor.black.withAlphaComponent(0.72)
        let icon = NSImageView(image: MemoGlyphs.lock(locked: true, pointSize: 30, ink: ink))
        icon.setAccessibilityLabel("잠긴 메모")
        message.textColor = ink
        message.font = .systemFont(ofSize: 13, weight: .medium)
        message.alignment = .center
        progress.style = .spinning
        progress.isDisplayedWhenStopped = false
        button.target = self
        button.action = #selector(submit)
        fields.password.target = self
        fields.password.action = #selector(submit)
        fields.password.widthAnchor.constraint(equalToConstant: 170).isActive = true
        fields.changed = { [weak self] in self?.button.isEnabled = LockCrypto.validPassword(self?.fields.password.stringValue ?? "") }
        button.isEnabled = false
        let stack = NSStackView(views: [icon, message, fields.password, button, progress])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24)])
    }
    required init?(coder: NSCoder) { fatalError("지원하지 않는 초기화") }
    @objc private func submit() {
        guard button.isEnabled else { return }
        let password = fields.password.stringValue
        fields.clear()
        button.isEnabled = false
        fields.password.isEnabled = false
        progress.startAnimation(nil)
        open?(password)
    }
    func finish(message: String) {
        progress.stopAnimation(nil)
        fields.password.isEnabled = true
        self.message.stringValue = message
        // 마지막 기회 경고는 붉은 글자로 눈에 띄게.
        self.message.textColor = message.contains("영구") ? .systemRed : NSColor.black.withAlphaComponent(0.72)
    }
}

private final class PasswordInputFormatter: Formatter, @unchecked Sendable {
    override func string(for obj: Any?) -> String? { obj as? String }
    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString
        return string == LockCrypto.filteredPassword(string)
    }
    override func isPartialStringValid(_ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let filtered = LockCrypto.filteredPassword(partialString)
        if partialString == filtered { return true }
        newString?.pointee = filtered as NSString
        return false
    }
}
